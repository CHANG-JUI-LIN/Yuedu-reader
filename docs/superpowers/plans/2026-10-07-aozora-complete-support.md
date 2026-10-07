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

**Status, 2026-10-07: code and tests written, nothing run, nothing released.** Written in a Linux cloud session without Xcode or a simulator, so no build or test in this record has run. Task 3 stops at the release checkpoint: the maintainer has not yet been asked to publish.

Commits:
- Package, branch `aozora-logical-properties` (from 0.7.0, 1fa83fa): 06a7a01 `feat(css): map CSS logical properties to physical sides by writing mode` (Task 1); b4fd57f `docs: record CSS logical properties for the next minor release` (Task 3, CHANGELOG `[0.8.0] - Unreleased` and README notes; the install instructions still say 0.7.0).
- App, branch `claude/zealous-bardeen-87ribn` (from main 0c3f6c7): 58783d5 `feat(reader): read CSS logical properties in the legacy engine` (Task 2). It uses no new package API, so it builds against 0.7.0.

Decisions made while implementing:
- **BrowserAuto maps at declaration time** (`LogicalGeometry.physicalProperty(forLogical:mode:)`, called from `ComputedStylePropertyApplier.apply`). The cascade's existing source order then gives CSS precedence; `max-inline-size` and `min-inline-size` are handled in the applier because their `none` / `auto` must clear the field.
- **The writing mode became a cascade input.** `BrowserChapterDocument.evaluate(configuration:writingMode:)` used to cascade with the configuration's own writing mode, which could differ from the one it judged; it now styles for the judged mode and stores it in the evaluation's configuration, and `CascadeInputs` includes `writingMode`. A pending evaluation is no longer rebound across a 排版方向 change (`BrowserLayoutPageEngine.chapterEvaluation` logs `admissionEvaluationStale` and evaluates again), where it used to keep the other mode's verdict.
- **`min-inline-size`** needed a field: `ComputedStyle.minWidth`, swapped with `minHeight` by `LogicalFlow.styleTree` and honoured over the maximum in `BlockLayout.resolveSides`. Physical `min-width` stays unparsed and vertical admission still refuses physical `min-height` / `min-width`, so no existing chapter changes. Legacy has no minimum line length and drops `min-inline-size`.
- **Legacy maps without the writing mode.** Its head indent is the inline start and paragraph spacing before the block start in both modes, so `margin-inline-start` → `margin-left`, `margin-block-start` → `margin-top`, `inline-size` → `width`, and so on (`LegacyLogicalProperties`), resolved in each block's source order. Legacy already drops `margin-top` in vertical writing (`paragraphSpacingBefore = 0`) and caps paragraph spacing at 1 em there; `margin-block-start` inherits that, unchanged.
- **Legacy `max-inline-size`** is `ResolvedStyle.maxInlineSize` → `RenderStyle.maxInlineSize` → a wider negative tail indent in `NodeAttributedStringRenderer`, measured along `renderWidth` (horizontal) or `renderHeight` (vertical). Not a positive tail indent: the horizontal line drawer and the decoration boxes read a paragraph's end only from a negative one. Not applied to right-aligned RTL paragraphs, which carry their inset in the head indent. A percentage resolves against `renderWidth` in both modes, like every other legacy percentage; the Aozora stylesheet uses `em` only.
- **Shorthand after a longhand in one block** (`margin-inline-start: 2em; margin: 0`): BrowserAuto lets the later `margin` win, as CSS does; legacy applies longhands after the shorthand whatever their order, as it already did for `margin-left`. The Aozora stylesheet never writes both.

Tests written, not run:
- Package: `Tests/YueduCoreTextTests/Engine/LogicalPropertyTests.swift` (cascade per side and mode, `none`/`auto`, order, the evaluation's writing mode, admission, and paged and continuous geometry for `margin-inline-start`, `max-inline-size`, `min-inline-size` and `text-align: end`); one assertion added to `SharedEvaluationEquivalenceTests.layoutRejectsChangedCascadeInputs`.
- App: `Tests/iOS/yuedu appTests/LegacyLogicalPropertyTests.swift`, through `EPUBAttributedStringBuilder` in both modes.

Still to do for Phase 2a: run the tests below on the maintainer's Mac, fix what fails, then Task 3 (publish 0.8.0 with the maintainer's yes, bump the app's requirement, merge). The screenshot probes and the corpus run belong to Phase 2b, where the stylesheet first uses these properties.

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

## Phase 2d — Ruby that BrowserAuto leaves to legacy

### Task 9: 左ルビ and readings on both sides

**Today:** the contract's second exception covers these.
- A word with right and left readings is a ruby inside a ruby: 82 chapters in 31 works go to legacy.
- `HorizontalRubySupport` refuses nested ruby, `rtc` and an `<img>` in a base.
- 左ルビ (15 works) uses `class="left"`, with no CSS yet.

- [ ] **Step 1 (package): failing tests.**
  - `ruby-position: under`: below the text in horizontal, on the left in `vertical-rl`.
  - Double-sided ruby: `<ruby>base<rt>right</rt><rtc style="ruby-position: under"><rt>left</rt></rtc></ruby>`, with both annotations placed and the text unchanged.
  - The capability scanner accepts both.
- [ ] **Step 2 (package): implement and release.** Same checkpoint as Task 3.
- [ ] **Step 3 (app, legacy).** `CTRubyAnnotationCreate` takes text for several positions at once (`kCTRubyPositionBefore` and `kCTRubyPositionAfter`). Use it for the double-sided form and for 左ルビ. Write a probe test in both writing modes.
- [ ] **Step 4 (writer; `converterVersion` + 1).**
  - A ruby inside a ruby becomes the `rtc` form.
  - `ruby.left` gets `ruby-position: under`.
  - Remove the ruby exception from the contract.
  - Update `AozoraEngineParityTests.holdsLegacyRuby` and the fixture chapter to expect BrowserAuto.
  - The corpus count of legacy ruby chapters in the conversion test must reach 0.
- [ ] **Step 5: A ruby over a figure.** It goes away with Task 10, or stays an exception. Record which.

## Phase 2e — Figures in vertical writing

### Task 10: Figures under BrowserAuto in vertical writing (GAPS S005)

**Today:** `VerticalTextSupport.accepts` (`LogicalFlow.swift` L119) refuses any `<img>` in vertical writing. Every Aozora chapter with a figure then goes to legacy, which also costs one U+FFFC per figure (the contract's figure exception).

- [ ] **Step 1: A design note first**, as GAPS.md S005 asks:
  - how an inline image takes a place in a column, and how much column length it uses;
  - block images;
  - which cases keep falling back.

  Ask the maintainer to approve it before coding.
- [ ] **Step 2: Inline images first, then block images.** Each in the package, released as in Task 3. Use the probe tests and the fidelity books `redchamber-vertical` and `kusamakura`.
- [ ] **Step 3 (app).**
  - Update the parity test's vertical expectation (`expectsBrowser`).
  - Narrow the contract's figure exception: the U+FFFC difference remains only for chapters that fall back for other reasons.

## Phase 3 — The long tail

Each task here is small in the census but may need engine work. Each starts with a short design note in this plan's "what landed" area and the maintainer's yes when it adds an engine feature. Constraint 1 applies to all of them: style only, the text unchanged.

### Task 11: 返り点 and 訓点送り仮名

Census: 470 works and 243 works.

- [ ] In vertical kanbun, 返り点 sit small at the lower left of a character and 送り仮名 small at the lower right.
- [ ] First do the CSS approximation, `.kaeriten { font-size: 0.5em; vertical-align: sub }` and `.okurigana { font-size: 0.5em; vertical-align: super }`. Check that both engines move them along the right axis in vertical writing.
- [ ] Record the gap to true kanbun placement, and propose the engine feature as its own design if the result is not readable.

### Task 12: 横組み inside vertical text

Census: 401 works.

- [ ] Today a `writing-mode` other than `vertical-rl` sends the chapter to legacy (`BrowserLayoutCapabilityScanner.declaration`).
- [ ] Decide with the maintainer whether to implement inline horizontal runs in BrowserAuto (a longer cousin of the 縦中横 cell), or to accept legacy for those chapters as a recorded exception.
- [ ] Map `.yokogumi` only after that decision.

### Task 13: 割り注

Census: 319 works.

- [ ] True 割り注 sets a note in two half-size lines within one line. CSS has no such feature.
- [ ] Start with `.warichu { font-size: 0.5em }`, keeping the （） the parser already adds.
- [ ] Propose the two-line layout as an engine design only if the maintainer asks.

### Task 14: 上付き, 下付き and 小書き in vertical writing

Census: 294 works.

- [ ] Probe how `<sup>` and `<sub>` sit in vertical writing in both engines, and fix whichever differs from WebKit.

### Task 15: ページの左右中央

Census: 225 works and 747 occurrences, about 712 of them unknown to the parser today.

- [ ] Teach the parser the annotation as a block style (tree only).
- [ ] Design centring for paged mode: the chapter's content centred on its page in both axes, as on a title page. In scroll mode it is centred in the viewport's inline axis.
- [ ] This is engine work in both engines. Get the design approved first.

### Task 16: Unknown annotations in the parser

**Source:** census `unknown_top`, and the corpus suite's "top unknown" line.

- [ ] Classify each shape before touching it.
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
- [ ] For each style-only shape, add a parser test, a writer rule and the four checks. Watch the corpus suite's unknown count fall.

### Task 17: 段組み

Census: 17 works.

- [ ] CSS columns are not supported by either engine. Record the decision not to map them unless the maintainer asks.

## Phase 4 — Housekeeping

### Task 18: One Aozora parser (Phase 1c, step 4 only)

- [ ] `AozoraMarkupParser`, used on the TXT path for every TXT chapter, delegates to `Modules/Core/Aozora` in a TXT-compatible mode:
  - it strips notes;
  - it keeps the kana-reading guard (Chinese 《》 are book-title marks);
  - it does no gaiji, accent or くの字点 conversion.
- [ ] `AozoraTXTTests` must pass **unchanged**. The TXT path's displayed text must not move: it has no migration either.
- [ ] Phase 1c steps 1–3 (coordinate-space tag, inverse projection, migration service) stay out of scope. The maintainer decides when there are Aozora readers to migrate.

### Task 19: Book information from the colophon

- [ ] The parser already keeps the colophon (卷末) as the last chapter. Extract 底本, 初出, 入力 and 校正 into the OPF:
  - `dc:source` for 底本 and its publisher;
  - `dc:contributor` with an MARC role code for each person, choosing a code where one fits and recording the choice;
  - a `meta` for 初出.
- [ ] Check what the app's book detail shows for a local EPUB, and show these fields there if it does not. The UI change follows `yuedu-ios-design`.
- [ ] Bump `converterVersion`; the chapter text is unchanged. Run the four checks and a regenerator test.

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
