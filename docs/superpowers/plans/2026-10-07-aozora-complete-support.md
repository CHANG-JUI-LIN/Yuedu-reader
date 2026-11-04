# Aozora Bunko: Complete Support — Implementation Plan

> **For astra.** Read [AGENTS.md](../../../AGENTS.md) first, then the sections of [CLAUDE.md](../../../CLAUDE.md) each task touches. Steps use checkbox (`- [ ]`) syntax for tracking.

**Background**
- Spec: [青空文庫支援設計](../specs/2026-10-05-aozora-bunko-support-design.md).
- What has landed: [Phase 0–1d](2026-10-05-aozora-bunko-support.md) (see its "what landed" sections).
- The text contract: [epub-text-contract.md](../../aozora/epub-text-contract.md).
- Evidence for priorities: [annotation census](../../aozora/annotation-census-2026-10-05.md).

**Companion plan:** [Public-domain libraries in Explore](2026-10-07-public-domain-libraries.md). It builds the in-app Aozora Bunko library: catalog, browsing, download into `AozoraBookImporter`. That library depends only on Phase 1b, so it can proceed in parallel with this plan. Do not run engine or package work from both plans at once.

**Goal:** after Phase 1d an Aozora book reads correctly. This plan makes it *look* the way Aozora Bunko lays it out, in both engines and both writing modes, in this order:
1. The CSS group: 字下げ, 地付き／字上げ, 見出し, 字級, 字詰め, 太字, 斜体, 罫囲み, キャプション, and 縦中横 (which the engines already support).
2. 傍点 and 傍線.
3. The ruby that BrowserAuto leaves to legacy today: 左ルビ, and a word with readings on both sides.
4. Figures in vertical writing under BrowserAuto.
5. The long tail, in census order.
6. Housekeeping: one Aozora parser, book information from the colophon, checks on a device.

**What the census expects** (works with no lost layout, of 17,158):
- today (ruby only): 28.5%;
- with the CSS group: 55.1%;
- with 傍点 and 傍線: 83.2%;
- with the long tail: about 100%.

The census dates from 2026-10-05. Since then, headings have become chapters and table-of-contents entries, and both engines can set 縦中横 once the stylesheet asks for it (Task 4).

---

## Constraints

1. **No change to the displayed text.**
   - **Why.** The maintainer skipped Phase 1c, the position migration (2026-10-07), so a chapter's text must never change: reading positions index it.
   - **What to bump.** Every change in this plan bumps `AozoraEPUBWriter.converterVersion` only. `textVersion` stays 1.
   - **The proof.** After every converter change, the corpus baseline `Tests/iOS/yuedu appTests/Fixtures/aozora-chapter-text-baseline.tsv` must still match.
   - **If a task can only be done by changing text, stop and ask the maintainer.** Examples: an annotation that turns `m` into `ṁ`, or a new character. Such a task needs Phase 1c's tools first.
2. **Both engines, both writing modes.**
   - BrowserAuto falls back to legacy per chapter, so a style drawn by only one engine makes chapters of one book look different. For 傍点 this is spec decision 5.
   - Every construct is checked in BrowserAuto paged, BrowserAuto scroll and legacy, horizontal and vertical.
3. **No new fallbacks to legacy.** `AozoraEngineParityTests` pins which engine lays out each chapter.
   - A mapping that would send chapters to legacy lands in BrowserAuto first.
   - Otherwise it is recorded as a contract exception, with the maintainer's agreement.
4. **Engine work is done in YueduCoreText and released as a package.** The app depends on the *published* package: `project.pbxproj` requires `https://github.com/CHANG-JUI-LIN/YueduCoreText` from 0.7.0, up to the next minor. Other agents build and test this checkout at any time, so follow this workflow exactly.
   - **App changes that call unreleased package API never reach `main`.** On 2026-10-06 one did, and every other agent's build failed until it was reverted (9182ebc8). `main` takes only changes that build against the released package.
   - **The package checkout.** `~/Desktop/YueduCoreText` stays on a `main` identical to `origin/main` (on 2026-10-07: tag 0.7.0, 1fa83fa, clean). Run `git -C ~/Desktop/YueduCoreText status` before starting: someone else may have work there. Never commit unreleased work onto that `main`.
   - **The package branch** lives in its own worktree, branched from `origin/main`:

     ```bash
     git -C ~/Desktop/YueduCoreText fetch origin
     git -C ~/Desktop/YueduCoreText worktree add -b aozora-<topic> ~/.config/superpowers/worktrees/YueduCoreText-aozora-<topic>/YueduCoreText origin/main
     ```

     **The last folder must be named `YueduCoreText`.** A workspace overrides a remote package with a local folder of the same identity, and a local package's identity is its folder name; any other name fails with "unable to override package (identity doesn't match)".
   - **The app branch** lives in a worktree of this repository (`.worktrees/` is ignored), branched from the local `main`, which may hold the maintainer's unpushed commits: `git worktree add -b aozora-<topic> .worktrees/aozora-<topic> main`.
   - **Build both through a workspace** that lists the app worktree's project and the package worktree, for example `/tmp/YueduAozora.xcworkspace/contents.xcworkspacedata` (`/tmp` is cleared now and then; recreate it at the same path):

     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <Workspace version="1.0">
       <FileRef location="absolute:/Users/zhangruilin/Desktop/Yuedu-reader/.worktrees/aozora-<topic>/Yuedu-Reader.xcodeproj"/>
       <FileRef location="absolute:/Users/zhangruilin/.config/superpowers/worktrees/YueduCoreText-aozora-<topic>/YueduCoreText"/>
     </Workspace>
     ```

     Run tests from the app worktree with `YUEDU_WORKSPACE=/tmp/YueduAozora.xcworkspace bash scripts/xctest.sh -- …`. Package tests (the package builds for iOS only, so not `swift test`): `YUEDU_PACKAGE_DIR=<package worktree> YUEDU_SCHEME=YueduCoreText-Package bash scripts/xctest.sh -- -only-testing:'<TestTarget>/<Suite>'`.
   - **Keeping up.** Rebase the package branch onto `origin/main` and the app branch onto the local `main`. After a rebase, desktop sync can leave copies named `<file> 2.swift` (same content, older timestamp) that break the build with duplicate definitions: compare them with the originals and delete them.
   - **Publishing a package release** (tag, GitHub release) is an outward action: **ask the maintainer first**, even though AGENTS.md describes publishing as part of a coordinated "commit". After approval: merge the package branch into the package's `main`, tag and push; in the app branch bump `minimumVersion` in `project.pbxproj`, run `xcodebuild -resolvePackageDependencies` so Xcode writes `Package.resolved`, verify with the normal project (no `YUEDU_WORKSPACE`), then merge the app branch into `main`.
5. **Existing books catch up by themselves.** A newer `converterVersion` with the same text makes `AozoraBookRegenerator` regenerate the EPUB on the next open (Phase 1b, Task 20). Each converter task checks this with `AozoraBookRegeneratorTests`.
6. **Stylesheet values are approximations.**
   - Aozora Bunko's own XHTML stylesheet lives on aozora.gr.jp, not in aozora2html, and the site is down as of 2026-10-07.
   - Use the values below. Once the site is back, compare them with the official stylesheet and record any differences in this plan.
7. **Project rules.**
   - Tests: `bash scripts/xctest.sh -- -only-testing:'yuedu appTests/<Suite>'`; no `-derivedDataPath`; delete your own `.xcresult` files.
   - Run the smallest relevant regression after the last related edit.
   - **Before touching vertical layout, run `CoreTextWritingModeTests`.**
   - **CSS properties:** adding to `ResolvedStyle` means mirroring it in `RenderStyle`, updating `RenderStyle.from`, and handling both rendering paths (CLAUDE.md, Critical Conventions).
   - **Shared worktree:** commit only your own files, with `git commit --only`.

## How each converter change is verified

Run all four after every task that changes the writer or the stylesheet:

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraXHTMLWriterTests' -only-testing:'yuedu appTests/AozoraEPUBWriterTests' -only-testing:'yuedu appTests/AozoraEngineParityTests' -only-testing:'yuedu appTests/AozoraBookRegeneratorTests'
TEST_RUNNER_AOZORA_CORPUS=$HOME/aozorabunko_text bash scripts/xctest.sh -t 3600 -- -only-testing:'yuedu appTests/AozoraCorpusTests'
```

- The corpus suite must pass.
  - The baseline must match: that is the proof of constraint 1.
  - The 50-work parity sample must read every chapter as planned in both writing modes, and send no chapter to legacy beyond the contract's exceptions.
- **Visual check: a screenshot probe for every construct.** Follow the pattern of `VerticalTypographyAcceptanceTests`.
  - Render a short self-written fixture in BrowserAuto paged, BrowserAuto scroll and legacy, in both writing modes.
  - Assert the geometry the CSS implies: offsets, alignments, mark positions.
  - Save the images for the "what landed" record.
- **Optional, horizontal only: the fidelity harness** (`docs/browser-layout/fidelity-loop/README.md`).
  - Convert three public-domain works heavy in 字下げ and 傍点, and add them to the EPUB test folder by the procedure in `ORACLE.md`.
  - WebKit then renders the same XHTML and CSS as the reference.

---

## Phase 2a — CSS logical properties

**Why first.** The converted EPUB declares no writing mode: the reader's 排版方向 decides it. So one stylesheet must be right in both writing modes. The engines disagree on physical properties in vertical writing:
- BrowserAuto keeps them physical, as CSS specifies (`LogicalGeometry.swift`: in `verticalRTL`, `margin-top` is the inline start).
- Legacy treats `margin-left` as the inline start in both modes.

Logical properties (`margin-inline-start`, …) say what Aozora means in both modes and in both engines. Neither engine parses them today.

### Task 1: Logical properties in BrowserAuto (package)

**Files (package)**
- `Sources/YueduCoreText/Engine/ComputedStyleTreeBuilder.swift`: the `case "…"` switch near L579–725.
- `Sources/YueduCoreText/Engine/LogicalGeometry.swift`
- The capability scanner (`BrowserLayoutCapabilityScanner.swift`, `layoutAffectingDeclaration`), so the new properties are not refused.
- New tests.

- [ ] **Step 1: Write the failing tests.**
  - **Cascade.** For each property, a declaration maps to the physical side for the configured writing mode:
    - The properties: `margin-inline-start/end`, `margin-block-start/end`, `padding-inline-start/end`, `padding-block-start/end`, `inline-size`, `max-inline-size`, `min-inline-size`.
    - Horizontal: inline-start = left, inline-end = right, block-start = top, block-end = bottom.
    - `vertical-rl`: inline-start = top, inline-end = bottom, block-start = right, block-end = left.
    - `inline-size` is width in horizontal and height in vertical.
  - **Order.** A logical and a physical declaration of the same side: the later one wins, as CSS has it.
  - **Geometry.** A paragraph with `margin-inline-start: 2em`:
    - starts 2em from the left in horizontal and 2em from the top in vertical;
    - `max-inline-size: 10em` wraps at ten characters in both modes;
    - `text-align: end` (already parsed) aligns to the right in horizontal and the bottom in vertical.
  - **The scanner** accepts the new properties in both modes.
- [ ] **Step 2: Implement.**
  - Map at declaration time, using the writing mode the builder already knows from `BrowserLayoutConfig`. Declaration order then gives CSS precedence for free.
  - Add a field only where a logical property has no physical counterpart yet, such as a minimum width.
- [ ] **Step 3: Run** the package tests (constraint 4: `YUEDU_PACKAGE_DIR=… YUEDU_SCHEME=YueduCoreText-Package bash scripts/xctest.sh`) and commit on the package branch.

### Task 2: Logical properties in legacy (app)

**Files**
- `Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift`: `ResolvedStyle` (L171) and its resolver `HTMLBuilderStyleResolver`.
- `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`: `RenderStyle` (L99) and `RenderStyle.from`.
- The paragraph-style application in `NodeAttributedStringRenderer.swift`.

- [ ] **Step 1: Write the failing tests.** The same cascade and geometry cases as Task 1, run through `EPUBAttributedStringBuilder` in both modes:
  - the head indent, the tail indent and paragraph spacing;
  - `max-inline-size` as a line length limit (if legacy has no such limit, implement it by clamping the frame width for that paragraph, or record why not);
  - `text-align: end`.
- [ ] **Step 2: Implement.**
  - Mirror every new field in `RenderStyle`, and handle both rendering paths: the string path and the `RenderableNode` IR path.
  - Legacy's head indent is already the inline start in both modes, so `margin-inline-start` maps to it directly.
  - Leave the physical properties' existing behaviour unchanged.
- [ ] **Step 3: Run and commit** (app branch, since it pairs with the package):

  ```bash
  bash scripts/xctest.sh -- -only-testing:'yuedu appTests/CoreTextWritingModeTests' -only-testing:'yuedu appTests/<new suite>'
  ```

### Task 3: Release the package (checkpoint)

- [ ] Write the package CHANGELOG entry (next minor, e.g. 0.8.0) and README notes.
- [ ] **Ask the maintainer to publish.**
- [ ] After the tag: bump the app's requirement and resolve the pin.
- [ ] Run the four checks above and `CoreTextWritingModeTests` with the normal project.
- [ ] Merge the app branch.

### Phase 2a: what landed

**Status, 2026-10-08: verified on the maintainer's Mac, not released.** Written in a Linux cloud session without Xcode; the maintainer ran the tests (iOS simulator, `scripts/xctest.sh`):
- package worktree, `LogicalPropertyTests`, `SharedEvaluationEquivalenceTests`, `VerticalLayoutTests`: 30 tests in 3 suites passed (first run: a compile error, fixed in 7c1bb8c);
- app through the override workspace, `CoreTextWritingModeTests`, `LegacyLogicalPropertyTests`, `AozoraEngineParityTests`: 33 tests in 3 suites passed;
- app with the normal project (released 0.7.0), `CoreTextWritingModeTests`, `LegacyLogicalPropertyTests`: passed.

A new worktree lacks the ignored `GoogleService-Info.plist`, and the Widget target then fails to build: copy it from the main checkout. No converter change, so no corpus run in this phase.

**Task 3, 2026-10-08.** YueduCoreText 0.8.0 published with the maintainer's approval: tag `0.8.0` on 783ce90 (`docs: prepare YueduCoreText 0.8.0`), fast-forwarded onto the package's `main`. The app requires 0.8.0 (c154368) and pins it in `Package.resolved`, edited as Xcode wrote the 0.7.0 pin (8be079d: revision and version only). The maintainer merged the app branch on the tests above; the four checks with the normal project against the published 0.8.0 are still to be run.

Commits:
- Package, branch `aozora-logical-properties` (from 0.7.0, 1fa83fa): 06a7a01 `feat(css): map CSS logical properties to physical sides by writing mode` (Task 1); 7c1bb8c (test fix); b4fd57f `docs: record CSS logical properties for the next minor release` (Task 3, CHANGELOG `[0.8.0] - Unreleased` and README notes; the install instructions still say 0.7.0).
- App, branch `claude/zealous-bardeen-87ribn` (from main 0c3f6c7): 58783d5 `feat(reader): read CSS logical properties in the legacy engine` (Task 2). It uses no new package API, so it builds against 0.7.0.

Decisions made while implementing:
- **BrowserAuto maps at declaration time** (`LogicalGeometry.physicalProperty(forLogical:mode:)`, called from `ComputedStylePropertyApplier.apply`). The cascade's existing source order then gives CSS precedence; `max-inline-size` and `min-inline-size` are handled in the applier because their `none` / `auto` must clear the field.
- **The writing mode became a cascade input.** `BrowserChapterDocument.evaluate(configuration:writingMode:)` used to cascade with the configuration's own writing mode, which could differ from the one it judged; it now styles for the judged mode and stores it in the evaluation's configuration, and `CascadeInputs` includes `writingMode`. A pending evaluation is no longer rebound across a 排版方向 change (`BrowserLayoutPageEngine.chapterEvaluation` logs `admissionEvaluationStale` and evaluates again), where it used to keep the other mode's verdict.
- **`min-inline-size`** needed a field: `ComputedStyle.minWidth`, swapped with `minHeight` by `LogicalFlow.styleTree` and honoured over the maximum in `BlockLayout.resolveSides`. Physical `min-width` stays unparsed and vertical admission still refuses physical `min-height` / `min-width`, so no existing chapter changes. Legacy has no minimum line length and drops `min-inline-size`.
- **Legacy maps without the writing mode.** Its head indent is the inline start and paragraph spacing before the block start in both modes, so `margin-inline-start` → `margin-left`, `margin-block-start` → `margin-top`, `inline-size` → `width`, and so on (`LegacyLogicalProperties`), resolved in each block's source order. Legacy already drops `margin-top` in vertical writing (`paragraphSpacingBefore = 0`) and caps paragraph spacing at 1 em there; `margin-block-start` inherits that, unchanged.
- **Legacy `max-inline-size`** is `ResolvedStyle.maxInlineSize` → `RenderStyle.maxInlineSize` → a wider negative tail indent in `NodeAttributedStringRenderer`, measured along `renderWidth` (horizontal) or `renderHeight` (vertical). Not a positive tail indent: the horizontal line drawer and the decoration boxes read a paragraph's end only from a negative one. Not applied to right-aligned RTL paragraphs, which carry their inset in the head indent. A percentage resolves against `renderWidth` in both modes, like every other legacy percentage; the Aozora stylesheet uses `em` only.
- **Shorthand after a longhand in one block** (`margin-inline-start: 2em; margin: 0`): BrowserAuto lets the later `margin` win, as CSS does; legacy applies longhands after the shorthand whatever their order, as it already did for `margin-left`. The Aozora stylesheet never writes both.

Tests:
- Package: `Tests/YueduCoreTextTests/Engine/LogicalPropertyTests.swift` (cascade per side and mode, `none`/`auto`, order, the evaluation's writing mode, admission, and paged and continuous geometry for `margin-inline-start`, `max-inline-size`, `min-inline-size` and `text-align: end`); one assertion added to `SharedEvaluationEquivalenceTests.layoutRejectsChangedCascadeInputs`.
- App: `Tests/iOS/yuedu appTests/LegacyLogicalPropertyTests.swift`, through `EPUBAttributedStringBuilder` in both modes.

Phase 2a is done. The screenshot probes and the corpus run belong to Phase 2b, where the stylesheet first uses these properties.

## Phase 2b — The CSS group

### Task 4: The Aozora stylesheet, version 2

**Files**
- `Modules/Core/Aozora/AozoraXHTMLWriter.swift`: replace the static `stylesheet` with a generated one.
- `AozoraEPUBWriter.swift`: `converterVersion = 2`.
- `AozoraXHTMLWriterTests`, `AozoraEngineParityTests` (fixture lines for each class).
- `docs/aozora/epub-text-contract.md`.

- [ ] **Step 1: Write the failing tests.**
  - The writer collects the classes a book uses, and writes rules for exactly those, in a stable order.
    - Example: a book with `jisage_2` and `jisage_10` gets two `jisage` rules and no others.
    - The same book always gives byte-identical CSS.
  - Each class maps as in the table below. Assert the CSS text, and the geometry through the probe pattern.
- [ ] **Step 2: The mapping.** `N` is the class's number.

  | Class | Rule |
  |---|---|
  | `jisage_N` | `margin-inline-start: Nem` |
  | `first_M` together with `jisage_N` | `text-indent: (M−N)em` (negative for 折り返して) |
  | `chitsuki_N` | `text-align: end; margin-inline-end: Nem` |
  | `jizume_N` | `max-inline-size: Nem` |
  | `dai1` / `dai2` / `dai3` | `font-size: 1.2em` / `1.44em` / `1.728em` |
  | `sho1` / `sho2` / `sho3` | `font-size: 0.833em` / `0.694em` / `0.579em` |
  | `o-midashi`, `naka-midashi`, `ko-midashi` (and the `dogyo-` / `mado-` forms) | `font-size: 1.5em` / `1.25em` / `1.1em`; `font-weight: bold` |
  | `futoji` | `font-weight: bold` |
  | `shatai` | `font-style: italic` |
  | `keigakomi` (block) | `border: 1px solid currentColor; padding: 0.5em` |
  | `keigakomi` (inline) | `border: 1px solid currentColor; padding: 0 0.1em` |
  | `caption` | `font-size: 0.833em` |
  | `tcy` | `text-combine-upright: all` |

  - Keep the existing rules: `br.eol { display: block }`, `p { margin: 0 }`, `.notes { font-size: 0.8em }`.
  - **No `writing-mode`, `@media`, floats or positioning** (the stylesheet limits in the contract).
  - **Values by number.**
    - Generate `jisage` and `chitsuki` rules for whatever `N` occurs.
    - Steps beyond 3 continue the factor 1.2.
  - **Before generating `tcy`:** check that both engines take `text-combine-upright: all` in vertical writing without falling back. YueduCoreText 0.7.0 and app commit 0470ce2e set authored 縦中横.
- [ ] **Step 3: Verify.**
  - Run the four checks.
  - **The parity sample must show no new legacy chapters.**
    - Any that appear point at a property one engine refuses, typically in vertical writing.
    - Fix that in the engine, or drop the rule and record why.
  - **Italic in vertical CJK.** Check how each engine draws it (synthetic oblique), and record it.
- [ ] **Step 4: Regeneration.** `AozoraBookRegeneratorTests` still passes: version 1 books regenerate, with the text unchanged.
- [ ] **Step 5: Records.**
  - Update the contract's "rules the writer follows".
  - Add a "Phase 2b: what landed" record here, with the screenshots.
  - Commit with `feat(aozora): set Aozora's layout annotations in both writing modes`.

### Phase 2b: what landed

**Status, 2026-11-04: done, on YueduCoreText 0.13.0.** Converter version 2; text version still 1.

**The stylesheet follows 青空文庫's own aozora.css, not the table above.** aozora.css (fetched 2026-11-04, Shift-JIS) and the inline styles aozora2html writes give the values; the table's guesses were wrong in four places:
- **Sizes.** aozora2html writes `１段階大きな文字` as `font-size: large`, a keyword relative to `medium`, not to the parent. The writer writes the keywords in `rem` with WebKit's proportions to `medium`:
  - up: 1.125, 1.5, 2 for three steps or more;
  - down: 0.8125, 0.625, 0.5625.
  - `rem` because both engines read it and it is relative to the reader's size, as a keyword is.
- **Headings.** aozora.css sizes h3 (大見出し) at 125%, h4 (中見出し) `large` and h5 (小見出し) `medium`, all bold:
  - so `o-midashi` 1.25em, `naka-midashi` 1.125rem, `ko-midashi` 1rem;
  - the rules go on the classes, so the 同行 and 窓 forms (a `span` with the same class) take them;
  - `h3, h4, h5 { margin: 0 }`.
- **罫囲み.** `border: 1px solid` (current colour, so themes still apply).
  - A run of 罫囲み blocks is one `<div class="keigakomi">`, as aozora2html draws it; it adds no text in either engine.
  - Its padding is aozora.css's: 0.5em on the block sides, 1em at the inline start, 0.5em at the end.
  - Inline 罫囲み is the border alone.
- **Small text.** `.notes` is `smaller`. `caption` is 0.8125rem and bold. `superscript`, `subscript`, `kaeriten` and `okurigana` are 0.8125rem.

**As planned:**
- `jisage_N` is `margin-inline-start`;
- `first_M` with `jisage_N` is `text-indent: (M−N)em`; a pair without 字下げ is written first, so source order agrees with specificity;
- `chitsuki_N` is `text-align: end; margin-inline-end`;
- `jizume_N` is `max-inline-size`;
- `futoji`, `shatai` and `tcy` as in the table.

**Also:**
- **傍点 and 傍線 are upright.** They are `em` elements, italic by default; aozora.css sets them `font-style: normal`, and so does the writer, for every emphasis and sideline class on both sides. The marks themselves are Phase 2c.
- **Rules only for what a book uses.** The stylesheet is written per book (`AozoraXHTMLWriter.stylesheet(forChapters:)`): the base rules, then one rule per class the chapters use, in a fixed order. The same book always gives the same bytes.

**Legacy honoured no CSS heading size.** `applyBlockStyle` scaled h2–h6 by its own factors whatever the book said: 中見出し came out 18.7pt instead of 19.125.
- An authored `font-size` on a heading now wins over that scale. It is passed as `ResolvedStyle.hasAuthoredFontSize` → `RenderStyle.hasAuthoredFontSize`, set by an author rule or the `style` attribute, not inherited.
- h1 keeps the app's scale. Unstyled headings in other EPUBs are unchanged.

**Italic in vertical CJK.**
- Both engines synthesise an oblique: a 0.2 shear in the font matrix.
  - BrowserAuto puts it on its CJK stand-in (`CJKFontLookup.standIn`); Latin takes the system's real italic.
  - Legacy puts it on the run's font.
- The same shear is drawn in vertical writing.
- **Finding, not fixed:** with no CJK stand-in (`cjk: nil`) and the system font, BrowserAuto's Han falls back to PingFang UI without the shear and is drawn upright.

**縦中横.** `text-combine-upright: all` takes no chapter to legacy in either mode: the parity sample shows no new legacy chapters.

**Verified:**
- **The four checks,** after the last edit (69 tests in 8 suites, with `CoreTextWritingModeTests` and `BookIntroLayoutTests`). `AozoraBookRegeneratorTests` regenerates version 1 books with the text unchanged.
- **The corpus** (`AozoraCorpusTests`, 712 s):
  - 17158 works parse;
  - every work converts and Readium opens it, every chapter keeping the baseline's text;
  - the 50-work parity sample reads as planned in both writing modes.
  - Chapters left to legacy are unchanged from before the stylesheet: 82 rubies inside a ruby in 31 works, 19 rubies over a figure in 1 work.
- **The geometry probe,** `AozoraStylesheetGeometryTests` (new), replaces the screenshots: no images were saved. One fixture uses every measured class. For BrowserAuto (paged) and legacy, each in both writing modes, it asserts where the text lands:
  - 字下げ, 折り返して, 地付き, 字上げ and 字詰め;
  - the size steps and the heading sizes and weights;
  - the 罫囲み box around its text;
  - 傍点 upright, 斜体 slanted.
- **Not probed: scroll mode.** The geometry probe lays out pages only. BrowserAuto's scroll path runs the same inline layout, but no test drives it with this stylesheet.

## Phase 2c — 傍点 and 傍線

**Impact:** 傍点 is in 35.9% of works and 傍線 in 1.9%. Neither engine draws emphasis marks. BrowserAuto has no `text-decoration` at all, which also affects ordinary EPUBs (`<u>`, `<s>`).

### Task 5: `text-decoration` in BrowserAuto (package)

- [ ] **Step 1: Failing tests.**
  - **Parsing:** `text-decoration`, `text-decoration-line` (underline, overline, line-through), `-style` (solid, double, dotted, dashed, wavy), `-color`, and `text-underline-position` (auto, under, left, right).
  - **Propagation:** a decoration applies to the text of descendants, as CSS propagates it.
  - **Geometry,** for a run in each writing mode:
    - Horizontal: underline below, overline above.
    - `vertical-rl`: `right` puts the underline on the right; `left` and the default put it on the left; overline is on the right.
  - **Line styles:** a double line is two rects; dotted and dashed are segment rects; wavy is a path.
- [ ] **Step 2: Implement** decorations as display-list items: `PageFragmentation`'s `fill`, or a new line item if needed. They must not add source text.
- [ ] **Step 3: Check all EPUBs.**
  - The UA defaults for `u`, `ins`, `s` and `del` should match WebKit.
  - Links: compare with what legacy and WebKit draw today, and do not change link appearance unasked.
  - Run the fidelity harness on the whole corpus and compare with the latest baseline. Report any book that moves.

### Task 6: `text-emphasis` in BrowserAuto (package)

- [ ] **Step 1: Failing tests.**
  - **Parsing:** `text-emphasis-style`:
    - `filled` / `open`;
    - `dot` / `circle` / `double-circle` / `triangle` / `sesame`;
    - a string such as `"×"`.

    Also `text-emphasis-position` (`over` / `under` with `right` / `left`), `text-emphasis-color`, and the `-webkit-` forms.
  - **Placement:**
    - One mark per typographic character unit, centred on it.
    - No mark on spaces, punctuation or control characters (CSS Text Decoration 3, §3.4).
    - Horizontal: `over` marks sit above and `under` marks below.
    - `vertical-rl`: `right` marks sit right and `left` marks left.
    - Marks take the annotation space a ruby would. Where a ruby and a mark meet, follow CSS: the ruby wins the side.
  - **The text contract:** a chapter's `sourceText` is unchanged by marks.
- [ ] **Step 2: Implement** in inline layout, reusing the ruby annotation machinery where it fits. Record the layout cost with the existing perf spans.

### Task 7: Emphasis and decoration in legacy (app)

- [ ] **Step 1: Failing tests.** The same placement assertions as Tasks 5–6, through `EPUBAttributedStringBuilder` in both writing modes.
- [ ] **Step 2: Choose the mechanism by probe, and record why.** Candidates for emphasis marks:
  - a `CTRubyAnnotation` per character, `before` or `after`;
  - drawing the marks in the page and scroll views as the 縦中横 cell is drawn (`CombinedUpright`).
- [ ] **Step 3: Decoration styles** (double, dotted, dashed, wavy) and the vertical sides: the right side for `text-underline-position: right`.
- [ ] **Step 4:** Text unchanged: legacy's string must still equal the plan (the parity test).

### Task 8: The writer's 傍点 and 傍線 rules

`converterVersion` + 1.

- [ ] **Step 1: The mapping.** The writer keeps aozora2html's class names.

  | Aozora | Class | CSS |
  |---|---|---|
  | 傍点 | `sesame_dot` | `text-emphasis-style: filled sesame` |
  | 白ゴマ傍点 | `white_sesame_dot` | `open sesame` |
  | 丸傍点 | `black_circle` | `filled circle` |
  | 白丸傍点 | `white_circle` | `open circle` |
  | 黒三角傍点 | `black_up-pointing_triangle` | `filled triangle` |
  | 白三角傍点 | `white_up-pointing_triangle` | `open triangle` |
  | 二重丸傍点 | `bullseye` | `filled double-circle` |
  | 蛇の目傍点 | `fisheye` | `open double-circle` |
  | ばつ傍点 | `saltire` | `"×"` |

  - **Use the writer's class names.** The class column here follows aozora2html. Use whatever `AozoraEmphasisStyle.className` actually returns and align this table to it.
  - **Position.** The plain classes use `text-emphasis-position: over right`. The `_after` (左に) classes use `under left`.
  - **傍線** (`underline_solid|double|dotted|dashed|wave`) is `text-decoration-line: underline` with the matching `text-decoration-style` and `text-underline-position: right`.
  - **左に傍線** (the writer's `overline_*` classes) uses `text-underline-position: left`.
    - Decision: in horizontal writing both draw under the text. aozora2html's horizontal HTML draws 左に傍線 over it.
    - The reason: one stylesheet serves both writing modes and must keep the vertical sides right. Record this.
- [ ] **Step 2: The four checks,** the probe screenshots, and a "Phase 2c: what landed" record.
  - The census's 「…」～「…」に傍点 range form is Task 16.
  - Commit with `feat(aozora): draw 傍点 and 傍線 in both engines`.

### Phase 2c: what landed

**Status, 2026-11-04: done, on YueduCoreText 0.14.1.** Converter version 3; text version still 1.

**Releases and commits.**
- Package 0.13.0: `text-decoration` and its longhands, `text-underline-position` and `-offset`, placed and snapped as WebKit places them (Task 5). 0.13.1 and 0.13.2 fix line boxes the probes found along the way: an inline box at `line-height: normal`, and WebKit's font-metric rounding (Times and Helvetica gain 15% above, rounded up; a Hiragino face keeps its own descent; found with S001i's `Hg` rows).
- Package 0.14.0: `text-emphasis`, as WebKit draws it in both writing modes, and lines grow to hold the marks (Task 6). 0.14.1 makes the emphasis values public (`YueduCoreTextTypography`), so legacy picks the characters that take a mark exactly as BrowserAuto does.
- App: `252aedff` (0.13.0), `85ee23ab` (0.13.2 and the WebKit layout probes), `4fee65a5` (0.14.1), `202819ff` (legacy, Task 7), `469ef7ba` (legacy's marks, made fast), and this commit (the writer, Task 8).

**Remeasured** (fidelity harness, iOS 27.2 simulator, 0.14.1 against 0.13.2): no chapter of the base or published sets regresses. kusamakura, which has 傍点, gains 0.2 on average. The emphasis fixtures gain 7.0 (S001i, horizontal) and 4.3 (S001j, vertical).

**Legacy's mechanism, chosen by probe (Task 7, Step 2): one `CTRubyAnnotation` per marked character**, at half size: `before` for over and right, `after` for under and left. The probe showed:
- each character's annotation stays its own mark, next to an identical one too;
- Core Text grows only the lines with marks, as WebKit does;
- only layout reads the ruby attribute, so speech, search and copied text never see a mark.

Drawing the marks in the page and scroll views, as 縦中横 cells are drawn, would have needed a second drawing path in both views.

**Legacy's lines.** Core Text has no line-through, overline or wavy line, and draws a vertical underline on the left only. `ReaderTextDecorationRenderer` therefore draws every line itself, placed and snapped as the package's `TextDecorationPainter` places them. **Before this, legacy's `<s>` and `<del>` were never struck through.** A mark or a line with no colour of its own takes its run's theme colour when drawn, so a theme change recolours it with the text.

**Legacy's limits, recorded:**
- A character under a ruby keeps the ruby and takes no mark. On the ruby's side CSS does the same; on the other side WebKit draws both, which one annotation per character cannot.
- A 縦中横 cell takes no mark; WebKit, and BrowserAuto, give it one.
- No skip-ink under Latin descenders.

**Legacy's marks were slow, and are fixed.** With one new annotation object per character, every mark was a new attribute value. On 43624 spine 1 (17 814 marks, found by the corpus run), `applyMarks` took 9 461 ms and the chapter's legacy build 9 979 ms. Two annotations per style, alternated between neighbouring characters, take 15–17 ms, and the build 454–518 ms. BrowserAuto lays the same chapter out in 1 206–1 280 ms (171 pages), inside its 5 s limit. An earlier 5–6 s reading was taken on a loaded machine.

**The writer (Task 8).** The class names are aozora2html's and match the table as planned. `AozoraEmphasisStyle.className` gives `sesame_dot`, `white_sesame_dot`, `black_circle`, `white_circle`, `black_up-pointing_triangle`, `white_up-pointing_triangle`, `bullseye`, `fisheye` and `saltire`.
- Each 傍点 class sets `text-emphasis-style` and `text-emphasis-position: over right`, and its `_after` (左に) class `under left`. Both properties are also written with the `-webkit-` prefix, for other WebKit-based EPUB readers.
- 傍線 is `text-decoration-line: underline` with the matching style and `text-underline-position: right`; 左に傍線 (`overline_*`) uses `left`. As decided: horizontally both draw under the text, where aozora2html draws 左に傍線 over it, because one stylesheet serves both writing modes and must keep the vertical sides right.
- 鎖線 (`*_dotted`) is `dotted`; 波線 (`*_wave`) is `wavy`.
- Every class keeps `font-style: normal` (Phase 2b).
- The census's 「…」～「…」に傍点 range form is Task 16.

**Verified:**
- **The four checks** after the last edit, with `AozoraEmphasisProbeTests` and `LegacyTextEmphasisDecorationTests`: 40 tests in 7 suites.
- **The corpus.** Its run for this commit was cut short by a restart of the Mac (the macOS 27.3 update). The corpus runs again with Task 9, over both tasks' changes; see Phase 2d.
- **The probe screenshots.** `AozoraEmphasisProbeTests` (new) converts one book with 傍点, 左に傍点, ばつ傍点, 傍線, 左に傍線, 二重傍線 and 波線, and lays it out in BrowserAuto and legacy in both writing modes. It asserts each construct's marks or lines as ink on the right side of its text and none on the other: the mark count, one line or two, a wave with more breaks than a solid line. The pages are in `2026-10-07-aozora-complete-support/phase-2c/`: `browser-h.png`, `browser-v.png`, `legacy-h.png` and `legacy-v.png`.

**Findings, not fixed:**
- In vertical writing WebKit draws a `filled circle` mark at the text's full size, unlike every other mark (a 46.25 column). Both engines draw it at half size (36.25).
- WebKit's horizontal filled triangle is a device pixel smaller each way than Hiragino's ▲, and up to a point higher. No installed font explains it, so both engines draw Hiragino's.

## Phase 2d — Ruby that BrowserAuto leaves to legacy

### Task 9: 左ルビ and readings on both sides

**Today:** the contract's second exception covers these.
- A word with right and left readings is a ruby inside a ruby: 82 chapters in 31 works go to legacy.
- `HorizontalRubySupport` refuses nested ruby, `rtc` and an `<img>` in a base.
- 左ルビ (15 works) uses `class="left"`, with no CSS yet.

- [x] **Step 1 (package): failing tests.** Done; the double-sided form is a ruby inside a ruby, not `rtc` (see the record).
  - `ruby-position: under`: below the text in horizontal, on the left in `vertical-rl`.
  - Double-sided ruby: `<ruby>base<rt>right</rt><rtc style="ruby-position: under"><rt>left</rt></rtc></ruby>`, with both annotations placed and the text unchanged.
  - The capability scanner accepts both.
- [x] **Step 2 (package): implement and release.** Same checkpoint as Task 3. YueduCoreText 0.15.0.
- [x] **Step 3 (app, legacy).** `CTRubyAnnotationCreate` takes text for several positions at once (`kCTRubyPositionBefore` and `kCTRubyPositionAfter`). Use it for the double-sided form and for 左ルビ. Write a probe test in both writing modes.
- [x] **Step 4 (writer; `converterVersion` + 1).** Done. The last bullet's 20 chapters, with a ruby over part of another ruby's base, went to BrowserAuto with YueduCoreText 0.17.0 (see "Phase 2f").
  - A ruby inside a ruby becomes the `rtc` form.
  - `ruby.left` gets `ruby-position: under`.
  - Remove the ruby exception from the contract.
  - Update `AozoraEngineParityTests.holdsLegacyRuby` and the fixture chapter to expect BrowserAuto.
  - The corpus count of legacy ruby chapters in the conversion test must reach 0.
- [x] **Step 5: A ruby over a figure.** It goes away with Task 10, or stays an exception. Record which. It stays an exception.

### Phase 2d: what landed

**Status, 2026-11-04: done, on YueduCoreText 0.15.0.** Converter version 4; text version still 1.

**Releases and commits.**
- Package 0.15.0 (`042fe86`): `ruby-position: under`, and a ruby whose base is one ruby as one ruby with two annotations. Annotations sit, and lines grow, as WebKit sets them: measured in a WKWebView on iOS 27.2 with the app's fixtures S001m (horizontal) and S001n (vertical), pinned by the package's `RubyPositionReferenceTests`.
- App: this commit (the pin, legacy, the writer and the contract).

**How WebKit sets ruby (iOS 27.2, 17px PingFang at 1.5, an 8.5px annotation).** The probes measured it; the package now follows it.
- An annotation stands on the base's content box (its font's ascent and descent rounded up): its baseline is 22 over the base's, or 16 under it; in `vertical-rl`, 19 either side of the column's centre. A second annotation on the same side sits 13 further.
- **A block's first line** is the union of the base's half-leading box and its annotations: 38.25 tall with one annotation, 51.25 with readings on both sides.
- **Every later line follows CSS Ruby 1 §4.4**: leading is added on an annotation's side only as far as the annotation reaches past the base's inline box. That gives 38 with one annotation and 63.5 with readings on both sides, because the outer annotation's need counts the inner one's annotation too. The first-line and later-line rules differ; the fixtures' `u1`–`ua` rows found it, a quarter point at a time.
- **No `rtc`.** WebKit lays an `rtc`'s text on the line, as base text. So the writer does not use the `rtc` form the plan's Steps 1 and 4 named: it keeps the ruby inside a ruby, which WebKit, and now BrowserAuto, set on both sides.

**The writer (converter version 4).**
- `ruby.left` (左ルビ) is `-webkit-ruby-position: after; ruby-position: under`.
- `ruby-position` is inherited, so a right ruby inside a left one is written `<ruby class="over">` (`ruby-position: over`); a left ruby inside a right one already names its side.
- A ruby inside a ruby with both readings on one side, such as 「ママ」 over a word with ruby, needs no class.

**Legacy.** `ruby-position` and `-webkit-ruby-position` are parsed (inherited). A ruby under its base is a `CTRubyAnnotation` at `after`. A ruby inside a ruby is one annotation with a text for each side (`CTRubyAnnotationCreate`): Core Text holds one ruby per range.
- **Limit, recorded:** Core Text has one text per side, so two readings on the same side keep the inner one, the base's own reading. 「ママ」 over a word with ruby is not drawn in legacy; BrowserAuto draws both.

**The ruby over a figure stays an exception (Step 5).** Task 10 is about figures in vertical columns; a figure as a ruby's base is a separate engine feature, and 黒死館殺人事件 is its only user (19 rubies). The contract keeps it as its one ruby exception.

**Verified:**
- **The four checks** after the last edit, with `AozoraRubyProbeTests` (new) and the ruby and scanner suites: 235 tests in 28 suites. 18 issues, all in three suites this task did not touch and that fail without it: `BrowserLayoutCapabilityScannerTests` still expects floats and tables to be refused (the package lays both out now), `BrowserLayoutInlineFormattingContextParityTests` pins fingerprints from before YueduCoreText 0.6.0, and one `BrowserLayout CSS text-indent` test.
- **The probe.** `AozoraRubyProbeTests` converts one book with 左ルビ, a word with readings on both sides, 「ママ」 over a word with ruby and a plain ruby. In BrowserAuto it finds each reading as ink on its side and none on the other, a second reading on the same side 13 further out; in legacy, one annotation over the whole base with the inner reading on each side, and the line grown on each side that has one. The pages are in `2026-10-07-aozora-complete-support/phase-2d/`: `browser-h.png`, `browser-v.png`, `legacy-h.png` and `legacy-v.png`.
- **The corpus** (iOS 26.5 simulator): 17 158 works parse in 68 s and convert into 113 562 chapters that Readium opens, each keeping the baseline's text. The largest work (2.1 MB, 324 chapters) converts in 2.0–2.7 s.
  - Of the 82 chapters (31 works) with a ruby inside a ruby, 62 now go to BrowserAuto. **20 chapters in 15 works still go to legacy**: their outer ruby's base is text beside an inner ruby, not one ruby, which 0.15.0 does not take. Three shapes: a note on part of a word, most often 「（ママ）」 (`<ruby><ruby>制<rt>（ママ）</rt></ruby>肘<rt>ちゅう</rt></ruby>`, 45641 spines 2–4); an `em` holding the inner ruby (50095); and one ruby over a whole kanbun sentence with its own 左ルビ, 送り仮名 and 返り点 (59114, and 58400 spine 75). `AozoraCorpusTests` expects none, and fails on these 20 until the package takes them: that follows Phase 2e.
  - The ruby over a figure: 19 in 1 work, as before.
  - **Parity** (50 works chosen for coverage): horizontal passes. Vertical fails on one chapter, 1323 spine 3, and not for its ruby: BrowserAuto takes the chapter now and its first page timed out (`fallbackToLegacy reason=timeout`), so legacy laid it out. The chapter is 400 KB of markup with thousands of rubies; BrowserAuto's admission took 3.6–4.5 s and its preparation 4.8 s, against the 5 s limit on preparation. The cause is measured and fixed with Phase 2e's pin.
- **Fidelity:** not remeasured here. The harness ran on the iOS 27.2 runtime, which no longer mounts after the macOS 27.3 update; Phase 2e remeasures on 26.5.

**Findings, not fixed:**
- An annotation wider than its base does not overhang its neighbours in BrowserAuto. WebKit lets it overhang by half the annotation's font size (4.25 at 8.5px).
- Two annotations on the same side of a later line take CSS Ruby's leading for both together, as two sides do. This is not measured.

## Phase 2e — Figures in vertical writing

### Task 10: Figures under BrowserAuto in vertical writing (GAPS S005)

**Today:** `VerticalTextSupport.accepts` (`LogicalFlow.swift` L119) refuses any `<img>` in vertical writing. Every Aozora chapter with a figure then goes to legacy, which also costs one U+FFFC per figure (the contract's figure exception).

- [x] **Step 1: A design note first**, as GAPS.md S005 asks:
  - how an inline image takes a place in a column, and how much column length it uses;
  - block images;
  - which cases keep falling back.

  Ask the maintainer to approve it before coding. Decided without review, as instructed; see the record.
- [x] **Step 2: Inline images first, then block images.** Each in the package, released as in Task 3. Use the probe tests and the fidelity books `redchamber-vertical` and `kusamakura`. Both in 0.16.0, by probe; the fidelity books are measured once with Phase 3.
- [x] **Step 3 (app).**
  - Update the parity test's vertical expectation (`expectsBrowser`).
  - Narrow the contract's figure exception: the U+FFFC difference remains only for chapters that fall back for other reasons.

### Phase 2e: what landed

**Status, 2026-11-04: done, on YueduCoreText 0.16.1.** Converter version 4 (no writer change); text version still 1.

**The design note (Step 1), decided without the maintainer's review, as instructed ("全部做完，別問我").** The measurements decided it: WKWebView on iOS 26.5 with the app's new fixture S005a-vertical-image-positions (the iOS 27.2 runtime no longer mounts after the macOS 27.3 update).
- **An inline image in a column.** It stays upright at its own size: its height runs down the column and is the length it takes there, its width lies across the column. It is centred on the column's central line, as text is, and the column widens to hold it: the column is as wide as its widest box. Measured: a 17×17 image leaves a 25 column at 25, a 40×10 one widens it to 40, a 10×40 one takes 40 down the column and leaves it at 25, 60×60 gives 60, and an image 48 wide by its `width` attribute (240×160, so 32 long) gives 48. On a paragraph's second line, only that line widens.
- **Block images.** A `display: block` image is a block as wide as the image, at the column's start. An image alone in a `div` or `p` with `text-align: center` (the writer's `p.figure`) is an inline image on a line of its own, centred down the column, as WebKit sets it: 240×160 in a 760 column with 1em margins starts 17 + 283 in.
- **An image longer than its column.** WebKit lets a 60×1000 image run 274 past the end of its 726 column. BrowserAuto scales it to the column, as it scales an image wider than its line in horizontal writing. **A deliberate difference**, kept for both writing modes: a page cannot scroll to the rest of the image.
- **What still falls back to legacy in vertical writing:** an image as a ruby's base (the ruby over a figure, Step 5 of Task 9: still the contract's one ruby exception), a floated image, an inline-block that is not an image, `svg`, `video`, `audio` and tables, a `max-width` anywhere, and a percentage `width`.

**Why one change covers both kinds.** The package lays vertical text out in canonical axes (inline along x, block along y) and turns the page at the end (`LogicalFlow`). An image's size now enters those axes turned (`BlockLayout.intrinsicSize`): its height inline, its width across. Lines, alignment, breaking and pagination then treat it as they treat a horizontal image. Only the baseline differs: an inline image's `AtomicInline.descent` is half its block size in vertical writing, so the line and the walker centre it on the central line. Before, images were refused in vertical writing (`VerticalTextSupport.accepts`), so nothing needed turning.

**Releases and commits.**
- Package 0.16.0: images inline and as blocks in vertical writing, pinned by `VerticalImageReferenceTests` against S005a.
- Package 0.16.1: styling and line layout no longer quadratic in a block's content (below).
- App: this commit (the pin, the parity test's vertical expectation, and the contract).

**Phase 2d's parity failure, measured and fixed (0.16.1).** 1323 spine 3 is 400 KB of markup with 13 489 rubies in 413 blocks. Once 0.15 took its nested rubies, BrowserAuto's preparation of it ran past the 5 s limit in vertical writing and the chapter fell back to legacy. A Time Profiler trace of the package's layout of that chapter (Debug, iOS 26.5 simulator) found two quadratic loops, not slow typesetting:
- **Styling** spent 83% of its time working out each element's semantic path from the element itself, which lists the element siblings of it and of every ancestor (`SwiftSoup`'s `elementSiblingIndex`). The style tree now builds each path from its parent's as it walks down; `StyleTreeSemanticPathTests` pins the strings.
- **Line layout** read every run of a block for each line's metrics, twice, and for each line's runs. A line now reads only its own runs, once, and a ruby's pieces take their fonts from the line's font cache, as its text does.

| Stage, warm (ms) | 0.16.0 | 0.16.1 |
|---|---|---|
| Styling | 3 400–4 500 | 620–730 |
| Capability scan (styles the chapter too) | 3 900–4 900 | 1 000 |
| Line layout, either writing mode | 3 300–4 300 | 1 470–1 880 |

Every fragment of the chapter lands where it did: the layout's fingerprint (each text and image fragment's source range and rect) is the same in both writing modes, 271 and 268 pages. The limit was not changed.

**The contract.** The figure exception narrows: BrowserAuto lays out vertical chapters with figures, so both engines' U+FFFC agree in every chapter BrowserAuto takes; a chapter with figures goes to legacy only for another reason (in the corpus, the ruby over a figure).

**Verified:**
- **The four checks** on 0.16.1, after the last edit (the Aozora, ruby, scanner, vertical and fingerprint suites): 235 tests in 28 suites. The same 18 issues as Phase 2d, in the same three suites that fail without this work (`BrowserLayoutCapabilityScannerTests`, `BrowserLayoutInlineFormattingContextParityTests`, one `BrowserLayout CSS text-indent` test). `AozoraEngineParityTests` passes in both writing modes with the figure chapters on BrowserAuto.
- **The package:** `VerticalImageReferenceTests` against S005a, `StyleTreeSemanticPathTests`, and the whole package suite on 0.16.1 (538 tests).
- **The corpus** (iOS 26.5 simulator): 17 158 works parse in 68 s and convert into 113 562 chapters that Readium opens, each keeping the baseline's text; the largest work converts in 1.7–1.9 s. The 20 chapters with partial nesting still go to legacy, so the conversion test still fails on `legacyNested.isEmpty`, as Phase 2d recorded; the ruby over a figure, 19 in 1 work, as before.
  - **Parity** (50 works chosen for coverage) passes in both writing modes. 1323 spine 3 now goes to BrowserAuto in vertical writing too: admission 952–966 ms (3.6–4.5 s before), preparation 2.6–2.9 s (4.8 s before, against the 5 s limit), its first page 30 ms. The margin is about 2 s in a Debug build on the simulator; Task 20 times it on a device.
- **Fidelity:** not remeasured in this phase. One run on 26.5, from YueduCoreText 0.14.1 to the last release of this plan, covers every phase since; it is recorded with Phase 3.

**Findings, not fixed:**
- WebKit on iOS 26.5 sets a plain 17px column at line-height 1.5 25 wide; on iOS 27.2 it was 25.5 (`RubyPositionReferenceTests`). BrowserAuto follows 27.2. The image tests pin how images sit against the text, so they hold on either.

### Phase 2f: a ruby over part of another ruby's base — what landed

**Status, 2026-11-04: done, on YueduCoreText 0.17.0.** Converter version 4 (no writer change); text version still 1. This finishes Task 9 Step 4: the corpus leaves no ruby inside a ruby to legacy.

**How WebKit sets it (WKWebView, iOS 26.5, 17px PingFang at 1.5, 8.5px annotations; the app's new fixtures S001o-partial-nested-ruby and S001p-vertical-partial-nested-ruby, 15 rows each).**
- An inner ruby is as wide as the wider of its base and its annotation, its base centred in it. The outer base runs on past it.
- The outer annotation spans the whole base, inner rubies and all. On a side it shares with an inner annotation it stands beyond it: 35 over the base's baseline, or 32 from the column's centre. On a side of its own it sits where a single annotation does: 22 over or 16 under, 19 either side of the column.
- Lines grow as for full nesting (Phase 2d): a first line with readings on both sides holds both, a later line takes CSS Ruby's leading.

**The package (0.17.0, `2344a9e`).** Full nesting is the case of one inner ruby over the whole base, so one path takes both: `HorizontalRubySupport` admits a base of text, inline elements and inner rubies of one base and one `rt`, `BoxTreeBuilder` records each inner ruby's span of base pieces, and `RubyInlineLayout` widens each span to its annotation, places the inner annotations next to the base and the ruby's own beyond them. `PartialNestedRubyReferenceTests` pins every row against S001o and S001p. The pronunciation hint stays the 0.15 rule when one inner ruby holds the whole base, and is the outer annotation otherwise. A ruby nested two deep, an inner ruby with several pairs and an `rtc` are still refused.

**The app.** The pin, and the capability and ruby tests now accept the partial shape and refuse one nested two deep. The contract's ruby exception narrows to the ruby over a figure.

**Verified:**
- **The package:** the whole suite on 0.17.0, 544 tests (49 + 495), with `PartialNestedRubyReferenceTests` and `ScriptShiftReferenceTests` (Task 14) new.
- **The four checks** after the last edit: 238 tests in 29 suites, with the same 18 issues as Phase 2d in the same three suites that fail without this work.
- **The corpus** (iOS 26.5 simulator): 17 158 works parse in 62 s and convert into 113 562 chapters that Readium opens, each keeping the baseline's text; the largest work converts in 1.7–1.8 s. Chapters with a ruby inside a ruby: 82 in 31 works, **left to legacy for it: 0** (20 before). The ruby over a figure: 19 in 1 work, as before. Parity (50 works) passes in both writing modes.

**Findings, not fixed** (the package's 0.17.0 known issues):
- WebKit spaces a base around under a wider annotation (`ruby-align: space-around`); BrowserAuto centres it, its characters together.
- An inner annotation wider than its base overhangs the outer base's text beside it in WebKit, by up to half its font size; BrowserAuto keeps it within the inner ruby. A base character after such a ruby sits 4.25 further along than in WebKit.
- Kana annotations fall back to Hiragino Sans in BrowserAuto, whose kerning narrows pairs such as ハイ and ザイ; WebKit sets them in PingFang, unkerned. A 14-kana annotation is 118.15 long, where WebKit's is 119. This holds for every ruby, nested or not.

## Phase 3 — The long tail

Each task here is small in the census but may need engine work. Each starts with a short design note in this plan's "what landed" area and the maintainer's yes when it adds an engine feature. Constraint 1 applies to all of them: style only, the text unchanged.

### Task 11: 返り点 and 訓点送り仮名

Census: 470 works and 243 works.

- [x] In vertical kanbun, 返り点 sit small at the lower left of a character and 送り仮名 small at the lower right.
- [x] First do the CSS approximation, `.kaeriten { font-size: 0.5em; vertical-align: sub }` and `.okurigana { font-size: 0.5em; vertical-align: super }`. Check that both engines move them along the right axis in vertical writing.
- [x] Record the gap to true kanbun placement, and propose the engine feature as its own design if the result is not readable.

### Task 12: 横組み inside vertical text

Census: 401 works.

- [ ] Today a `writing-mode` other than `vertical-rl` sends the chapter to legacy (`BrowserLayoutCapabilityScanner.declaration`).
- [x] Decide with the maintainer whether to implement inline horizontal runs in BrowserAuto (a longer cousin of the 縦中横 cell), or to accept legacy for those chapters as a recorded exception.
- [ ] Map `.yokogumi` only after that decision.

### Task 13: 割り注

Census: 319 works.

- [ ] True 割り注 sets a note in two half-size lines within one line. CSS has no such feature.
- [x] Start with `.warichu { font-size: 0.5em }`, keeping the （） the parser already adds.
- [ ] Propose the two-line layout as an engine design only if the maintainer asks.

### Task 14: 上付き, 下付き and 小書き in vertical writing

Census: 294 works.

- [x] Probe how `<sup>` and `<sub>` sit in vertical writing in both engines, and fix whichever differs from WebKit.

### Task 15: ページの左右中央

Census: 225 works and 747 occurrences, about 712 of them unknown to the parser today.

- [x] Teach the parser the annotation as a block style (tree only).
- [x] Design centring for paged mode. Decided in the session (the maintainer asked for the whole plan, 2026-11-04): the block axis only, a chapter that fits on one page; scroll mode unchanged. See "Task 15: what landed".
- [x] Engine work in both engines: YueduCoreText 0.18.0 and the legacy paginator.

### Task 16: Unknown annotations in the parser

**Source:** census `unknown_top`, and the corpus suite's "top unknown" line.

- [x] Classify each shape before touching it.
  - **Style only** (allowed):
    - 「…」～「…」に傍点 and its 白丸 form (range forward references, about 200 occurrences);
    - はゴシック体 and the other typefaces (`font-family: sans-serif`);
    - 小書き (a smaller size);
    - 横N列;
    - 上に「…」付き, as a ruby-like note;
    - N段組み: no mapping, recorded.
  - **Text-changing** (blocked by constraint 1; ask the maintainer):
    - letters with dots, such as 「mは上ドット付き」 → ṁ;
    - 分数, if it would compose characters.
- [x] For each style-only shape, add a parser test, a writer rule and the four checks. Watch the corpus suite's unknown count fall.

### Task 17: 段組み

Census: 17 works.

- [x] CSS columns are not supported by either engine. Record the decision not to map them unless the maintainer asks.

### Phase 3: what landed

**Status, 2026-11-04: verified in the simulator (iOS 26.5, `scripts/xctest.sh`), not released.** No new package version: the shift both engines use, `VerticalAlignShift`, shipped in YueduCoreText 0.17.0 with `ScriptShiftReferenceTests` pinning BrowserAuto to WebKit 26.5 (S013 and S013a fixtures). Converter version 5. The maintainer asked for the whole plan without being asked (2026-11-04), so every decision below was made in the session and is recorded here for veto.

What each task did:
- **Task 11, 返り点 and 訓点送り仮名.** The CSS approximation, `.kaeriten { font-size: 0.5em; vertical-align: sub }` and `.okurigana { font-size: 0.5em; vertical-align: super }`.
  - Legacy used to ignore `vertical-align` entirely, so 送り仮名 and 返り点 sat on the baseline there. It now moves a `super` run up by its parent's size / 3 + 1 and a `sub` run down by / 5 + 1, as WebKit does (`RenderStyle.verticalAlign`, applied as a `.baselineOffset` in `NodeAttributedStringRenderer.applyInlineStyle`); Core Text turns the offset with a vertical line's glyphs, so up is right of the column.
  - Measured in legacy (`AozoraScriptShiftProbeTests`, 17pt, the ink's centre against the same text with `vertical-align: baseline`, 3× pixels): 送り仮名 +6.67 in horizontal and vertical, paged and scroll (expected 6.67); 返り点 −4.33 horizontal and −4.67 vertical (expected −4.40, a pixel either way). BrowserAuto agrees with WebKit within 0.02pt.
  - **The gap to true kanbun placement.** Print sets a 返り点 at the lower left of the character before it and a 送り仮名 at its lower right, taking no room along the line. The approximation puts them after that character, each advancing the line by its own (half) size, so a kanbun line runs about half as long again as in print. It reads correctly and in order. True placement would be an engine feature, an inline that takes no advance and hangs off the previous character like a ruby on the leading side; not proposed, since the approximation is readable.
- **Task 12, 横組み in vertical text: not mapped (decided).** The contract forbids `writing-mode` in the stylesheet, and mapping `.yokogumi` to `writing-mode: horizontal-tb` would send each of those chapters (401 works) to legacy, which cannot lay an inline horizontal run either. The class stays unstyled: the text keeps its place in the column, Latin sideways as everywhere else. Reopen only with an engine design for inline horizontal runs.
- **Task 13, 割り注.** `.warichu { font-size: 0.5em }`, inside the （） the parser already adds; it stays on the baseline. The two-line layout was not proposed.
- **Task 14, 上付き and 下付き in vertical writing.** Probed in both engines: BrowserAuto matched WebKit; legacy did not move them at all, fixed by Task 11's shift. 小書き maps to one step smaller (Task 16). Known difference, recorded in the package's CHANGELOG: a vertical superscript grows its column by 4.28 in BrowserAuto against WebKit's 3.66.
- **Task 15, ページの左右中央: parser only in this phase.** ［＃ページの左右中央］, and the ［＃ここから…］ / ［＃ここで…終わり］ pair, set `AozoraParagraphStyle.isPageCentered` on the blocks after it until the next page break. The unknown-annotation count no longer holds them. The writer and both engines followed after Phase 4: see "Task 15 (ページの左右中央): what landed".
- **Task 16, style-only shapes** (the text-changing ones stay blocked by constraint 1):
  - 「X」〜「Y」に傍点, a range forward reference, with U+301C or U+FF5E between the quotes, for every style (傍点, 傍線, 太字 …): the nearest Y before the note, then the nearest X before it;
  - ゴシック体 and ゴチック → `.gothic { font-family: sans-serif }`;
  - 小書き → one step smaller;
  - 横一列 → 縦中横 (the corpus has no 横二列 or 横三列);
  - 傍点（白丸）→ white-circle 傍点;
  - 「X」は上に「Y」付き → Y as a ruby-like note over X;
  - ［＃この行は…］ applies its style to the rest of its line.
  - What is left in the corpus's top unknown shapes is editorial cross-references (「三五頁」は「須佐の男の神」の「穀物の種」), 分数, 段組み and dotted letters.
- **Task 17, 段組み: not mapped (decided).** Neither engine supports CSS columns.

**Fidelity, Phases 2c to 4** (the one run Phase 2e promised; iOS 26.5 simulator, 2026-11-05): the 0.14.1 tree (app dd1e3713, package 0.14.1) against main at 9485459f with package 0.17.0, all three corpora, dev and holdout. Task 15 is not in it: no chapter of the corpora carries `zy-page-align`.
- **Base** (455 comparable chapters of 473): PASS. No book moves but kusamakura, +0.5 (67.7 → 68.2), from 傍点 and ruby.
- **Publishers** (96): no change.
- **Gaps** (40): ruby that used to go to legacy now lays out under BrowserAuto and gains 13 to 26 (S001m +26.2, S001n +20.8, S001o +25.0, S001p +13.1); vertical figures gain 33.8 (S005) and 26.1 (S005a); S001j, vertical emphasis, +2.8.
- **The harness's verdict on gaps is FAIL, for one fall: S001i (horizontal emphasis), 89.3 → 87.8** (0.5 allowed), layout 94.1 → 94.2, visual 76.9 → 71.4. It is the ruby work, and the line it changes is closer to WebKit, not further. The fixture's line with ruby under the same marks (`<span class="fs"><ruby>漢<rt>かん</rt></ruby>字</span>`) stands 65 below the line before it in WebKit; 0.14.1 gave it 60.5, 0.17.0 gives 63.0, so every line after it sits 2.48 lower. Every other line of the fixture, in both runs alike, runs 0.5 to 0.75 lower than WebKit's, one more each line: the engine's 17px line at 1.5 is 25.5, WebKit's on iOS 26.5 is 25 (on 27.2 it is 25.5, which is what Phase 2c measured against). 0.14.1's short ruby line happened to cancel that drift; 0.17.0's cancels less of it. Recorded, not fixed: the ruby line is still 2.0 short of WebKit's (how WebKit sets marks and ruby on one side was not probed), and the 26.5 line-height rounding is a runtime difference.

Corpus (17158 works, `AozoraCorpusTests`): unknown annotations from 2556 in 524 works to 1288 in 280; every chapter of every work keeps the baseline's text; the parity sample is green in both modes; a ruby inside a ruby sends no chapter to legacy. The test run: 333 tests in 32 suites, the only failures the 18 known before this phase (`BrowserLayoutCapabilityScannerTests`' floats and tables, `BrowserLayoutInlineFormattingContextParityTests`' fingerprints, one `BrowserLayout CSS text-indent` test).

## Phase 4 — Housekeeping

### Task 18: One Aozora parser (Phase 1c, step 4 only)

- [x] `AozoraMarkupParser`, used on the TXT path for every TXT chapter, delegates to `Modules/Core/Aozora` in a TXT-compatible mode:
  - it strips notes;
  - it keeps the kana-reading guard (Chinese 《》 are book-title marks);
  - it does no gaiji, accent or くの字点 conversion.
- [x] `AozoraTXTTests` must pass **unchanged**. The TXT path's displayed text must not move: it has no migration either.
- [x] Phase 1c steps 1–3 (coordinate-space tag, inverse projection, migration service) stay out of scope. The maintainer decides when there are Aozora readers to migrate.

### Task 19: Book information from the colophon

- [x] The parser already keeps the colophon (卷末) as the last chapter. Extract 底本, 初出, 入力 and 校正 into the OPF:
  - `dc:source` for 底本 and its publisher;
  - `dc:contributor` with an MARC role code for each person, choosing a code where one fits and recording the choice;
  - a `meta` for 初出.
- [x] Check what the app's book detail shows for a local EPUB, and show these fields there if it does not. The UI change follows `yuedu-ios-design`.
- [x] Bump `converterVersion`; the chapter text is unchanged. Run the four checks and a regenerator test.

### Phase 4 (Tasks 18 and 19): what landed

**Status, 2026-11-04: verified in the simulator (iOS 26.5), not released.** Converter version 6. Phase 3 is app commit 030a3812.

**Task 19, the colophon.**
- The writer puts it in the package, never the text: 底本 as `dc:source`, 初出 as `<meta property="dcterms:bibliographicCitation">`, 入力 and 校正 as `dc:contributor`s refined with MARC relator roles. A field over several lines (底本 and its printing) is joined into one line with a space.
- **Role codes (decided).** 入力 is `trc`, transcriber: the person who keyed the printed text in. 校正 is `pfr`, proofreader. Neither is in Readium's known roles, so both land in `Metadata.contributors` with their role, never among the authors; `dcterms:` is a reserved prefix in EPUB 3, so the package declares none.
- **Import.** `ImportedMetadataCapture.EPUBColophon` reads the four from Readium (`otherMetadata` under `http://purl.org/dc/terms/source` and `…/bibliographicCitation`; the people by role) into four new sidecar fields, `printedSource`, `firstAppearance`, `transcribers`, `proofreaders`. Every place that reads an EPUB's package for metadata reads them: the import (`BookStore`), `ImportedMetadataCapture.reread`, and the WebDAV filler. Any EPUB that names them keeps them in its sidecar, but only a converted 青空文庫 text shows them: Project Gutenberg's packages name their own URL as `dc:source`, which is no 底本.
- **Books converted before version 6** get them when they open: `ConvertedBookRegenerator.prepare(book:)` rereads the copy's package into its sidecar after a regeneration (the one path, `reread`, that the series backfill already uses). The sidecar is local, so nothing syncs.
- **Book detail.** Before, a converted copy showed only 來源, 格式 and 檔案大小; the catalogue's own page showed 底本 and 出版社. The work page of a converted copy now adds 底本, 初次發表, 輸入 and 校對 rows from its sidecar (`WorkDetailView.colophonItems`), skipping 底本 on a catalogue version, which has its own. Plain label and value rows of `BookDetailInfoSection`, read by VoiceOver as the other rows are. New keys in all five languages: 初次發表, 版權頁：輸入 (輸入 already meant the verb), 校對.
- Tests: `AozoraEPUBWriterTests` (the package, and Readium reading it back as an `EPUBColophon`; 初出 over two lines), `AozoraBookRegeneratorTests` (the sidecar at import, and again after an older book regenerates).

**Task 18, one parser.**
- `AozoraMarkupParser` (the TXT reader, every TXT chapter) no longer scans the markup itself: it reads each piece through `AozoraTokenizer.markup(in:at:limit:dialect: .txt)`, the converter's tokenizer in a TXT-compatible dialect, and keeps only its own policy: notes hidden, ruby shown, the kana guard for bare 《》 (Chinese book-title marks), Han-only implicit bases, no gaiji, accent or くの字点 conversion.
- **The TXT reading is the old reader's, exactly**, because its displayed text has no position migration. It reads in two passes, as the old reader did:
  - notes first, found as NSString finds them (`AozoraTokenizer.txtNotes`): ［＃ does not nest, the first ］ closes it (the converter follows aozora2html and nests), and a ［＃ or ］ with a combining mark after it is not a delimiter;
  - then ruby, on the text with the notes taken out, by Swift character: a ｜, 《 or 》 that shares a character with its neighbour (a combining mark, a variation selector, a ZWJ) is text, so the parser masks it before the tokenizer sees it. A reading also ends at U+000B, U+000C, U+0085, U+2028 and U+2029 (`Character.isNewline`).
  - The document dialect is unchanged.
- The old implementation is frozen in `AozoraMarkupParserEquivalenceTests` as the oracle, and the new one must give the same nodes, displayed text, hidden notes and removed ruby markup:
  - 200,000 random strings (seed 0x5EED_2026_1104) over the delimiters, line ends of every kind, Han of both planes, kana, and the characters that join a delimiter to its neighbour: no difference. A first, one-pass version differed on 10,949 of 300,000 such strings, all with a combining mark or ZWJ beside a delimiter; it was rewritten into the two passes above.
  - The TXT fixtures (`Fixtures/TXTEncodings`) and every work of the corpus (17158): no difference.
  - `AozoraTXTTests` pass unchanged.
- **Time.** The largest 200 works (59,043,785 UTF-16 units), each read whole on the simulator (iOS 26.5): 16.31 s with the old reader, 15.96 s with the new. On macOS, the largest work alone: 164 ms before, 148 ms after.
- Phase 1c steps 1–3 stay out of scope, as planned.

### Task 15 (ページの左右中央): what landed

**Status, 2026-11-05: verified in the simulator (iOS 26.5), not on a device.** YueduCoreText 0.18.0 and 0.18.1; converter version 7. The maintainer asked for the whole plan without being asked (2026-11-04), so the design below was decided in the session and is recorded here for veto.

**Census** (17158 works, the parser's `isPageCentered`): 213 works hold it, and every one of their 707 marked chapters is marked whole; no chapter mixes centred and uncentred blocks, because the annotation runs to the next page break and a page break ends a chapter. 570 of the 707 hold one text block, and 637 hold at most 16 blocks of at most 40 characters, a title page or a dedication. The largest is 167 blocks (3235 characters), which pages as before.

**Decisions.**
- **Block axis only.** 左右中央 is the block axis of vertical writing, the way the works are set: the line's own position (its 字下げ, or the full-width spaces before it) stays where the source puts it, and the page centres the lines as a group, right to left. Horizontal writing centres the same group top to bottom. The earlier design note also centred each line in the inline axis; that would undo the source's own indents, so it was dropped.
- **The signal is a body property, not a class or CSS.** CSS cannot centre a page's content in either engine, so the writer marks a chapter wholly under the annotation with `<body style="zy-page-align: center">` (`AozoraXHTMLWriter.isPageCentred`), as `zy-fontsize-adjust` already marks a fixed-size chapter. `PublicationPageAlignment` reads it for both engines. WebKit ignores the unknown property; the text is unchanged (the parity test now holds a centred chapter).
- **Only a chapter that fits on one page moves, and only in paged mode.** A longer chapter, and scroll mode, lay out as before. A move under a point is not made.
- **BrowserAuto** (`BrowserLayoutConfig.centersSinglePage`): both paged walkers, the session and the batch, take their page insets from one helper, `LogicalFlow.pageInsets`, which grows the block-start inset until what the page paints, the chapter's line boxes and block images, sits in the middle. Every fragment moves with it, so painting, selection, search and TTS highlights follow. It is geometry, not a cascade input, so an admitted evaluation is reused.
  - 0.18.0 centred the chapter's whole box. The app test caught it: the body's 8px margin, which the user agent gives it as WebKit's does, stands before the first line and after the last, and the reader's paragraph spacing follows the last line too; none of it paints, and the title page sat 4 points high at 8 points of spacing (gaps 181.5 and 189.5). 0.18.1 centres the painted extent, and never moves the chapter further than its whole box leaves room for, so it stays on one page.
- **Legacy** (`CoreTextPaginator.computeLayout`): when the one page's lines leave room, the chapter is laid out again with its insets translated along the block axis by `centringShift`, the path the same size, so the same lines land in the middle. Every page view rebuilds its frame, its hit-testing and its drawing from the layout's insets, so they follow. The shift comes from the lines' typographic extents (ascent and descent), skipping lines with nothing visible.

**Measured** (`AozoraPageCentringTests`, 320×480 page, insets 20/16/30/24 so a centre taken from the wrong edge shows, 17pt, 8pt paragraph spacing; a title page of two lines):
- BrowserAuto, the space before and after the line boxes: 185.5 and 185.5 horizontal, 110.5 and 110.5 vertical (right and left).
- Legacy, the space before and after the ink, painted as a page view paints it: 191.0 and 189.7 horizontal, 111.7 and 114.3 vertical. Ink is not the line box: a glyph's ink sits a little off its line's centre, so the test allows 4.
- A chapter that does not ask stays at the top of its page in both engines, and the centred chapter's text is the planned text (the parity test now holds one).

**Fidelity**: unchanged by this task. No chapter of the fidelity corpora asks to be centred; Phase 3 records the run.

Tests: `AozoraPageCentringTests` (new), `AozoraEngineParityTests`, `AozoraEPUBWriterTests`, `AozoraXHTMLWriterTests`, `AozoraBookRegeneratorTests`, `AozoraCorpusTests`, `LegacyTextEmphasisDecorationTests`, `AozoraScriptShiftProbeTests`, `BottomJustifyPaginationTests`, `BrowserBottomJustifyEngineTests`, `ContentRevisionPaginationTests`, `CurlRepaginationNeighbourTests`, `RedChamberProductionRenderingRegressionTests`: 70 tests in 13 suites pass (iOS 26.5). The package: 49 XCTest and 500 Swift Testing tests pass, `BrowserPageCentringTests` among them.

### Task 20: Checks on a device

- [ ] On a physical iPhone, time the largest work (`50685_ruby_67979`, 2.1 MB) with the `aozora.parse`, `aozora.import.convert` and `aozora.regenerate` spans.
- [ ] Render the 55 gaiji outside the BMP (3.8% of works) and look for missing glyphs.
- [ ] Read one converted work in vertical writing, paged and scroll.
- [ ] Record everything in this plan.
- [ ] **This needs the maintainer's device.** Ask; do not substitute the simulator.

### Task 21: TTS and ruby readings (ask first)

- [ ] The spec lists 「TTS 依注音讀法發音」 as a non-goal. Ask the maintainer whether to reverse that before doing anything.

### Task 22: Migrating existing TXT Aozora books (deferred)

- [ ] Phase 1c steps 1–3 (2026-10-05 plan) stay deferred by the maintainer's decision of 2026-10-07.
- [ ] Reopen them only if asked. Doing so is also what unblocks any text-changing task in Task 16.

---

## Records

At the end of each phase, add "Phase 2x: what landed" to this plan:
- the commits (app and package);
- the package versions;
- the corpus results (baseline match, parity sample, legacy-chapter counts);
- the census expectation against the measured result;
- the screenshots;
- every decision made while implementing.

Update `docs/aozora/epub-text-contract.md` whenever a rule or an exception changes.

## Acceptance for the whole plan

- [ ] **Baseline:** the corpus baseline matches after every phase. `textVersion` is still 1.
- [ ] **Parity:** in both writing modes, every chapter of the parity sample goes to BrowserAuto, apart from the exceptions the contract still lists. All three engines' texts match the plan.
- [ ] **The CSS group, 傍点 and 傍線, and 左ルビ / double-sided ruby** are drawn the same in both engines and both writing modes, by probe and by screenshot.
- [ ] **Existing converted books** regenerate on open to the newest `converterVersion`, with their positions untouched.
- [ ] **Fidelity:** no book in the fidelity corpus regresses from the `text-decoration` work.
