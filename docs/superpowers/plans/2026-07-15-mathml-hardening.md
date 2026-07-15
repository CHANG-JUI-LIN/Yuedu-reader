# MathML Attachment Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make official-sample MathML align with surrounding text, size and rasterize once against the real paragraph width, remain clear when fitted, and preserve meaningful fallback text when conversion or iosMath rendering fails.

**Architecture:** Keep the existing MathML → MathMLToLaTeX JS → iosMath → raster attachment pipeline. Move formula-specific sizing into a focused `MathMLAttachmentMetrics` policy, pass the actual paragraph content width into the rasterizer before drawing, and represent conversion failure explicitly in the IR so the renderer—not generic HTML recursion—owns fallback output. Existing generic image metrics remain unchanged.

**Tech Stack:** Swift 6, SwiftSoup AST, JavaScriptCore, iosMath 2.3.1, UIKit rasterization, CoreText CTRunDelegate attachments, Swift Testing.

---

## Prerequisite

Complete the corpus harness plan and record the Linear Algebra baseline checkpoints first. Every green behavior already present at `build-week-baseline` is documented as `baseline-supported`; only a reproduced baseline failure can be labeled `build-week-fixed`.

## File Responsibility Map

- `Modules/Core/ReaderCore/CoreText/MathMLRendering.swift`: MathML serialization/conversion, iosMath display-list rasterization, and conversion/render error values.
- `Modules/Core/ReaderCore/CoreText/MathMLAttachmentMetrics.swift`: formula-only logical width, height, ascent, descent, and scale policy.
- `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`: MathML IR payload capable of carrying conversion failure and alt text.
- `Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift`: always produces a MathML node for `<math>`, even when conversion fails.
- `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`: requests the final raster at actual available width and emits attachment or fallback text.
- `Tests/iOS/yuedu appTests/EPUBTestFixtures+MathML.swift`: minimal synthetic EPUB cases only; no official sample binary/text dump.
- `Tests/iOS/yuedu appTests/MathMLBaselineTests.swift`: raster and CTRunDelegate geometry assertions.
- `Tests/iOS/yuedu appTests/EPUBRenderingTests.swift`: AST/IR fallback and surrounding-text assertions.

### Task 1: Expand minimal MathML fixtures and capture RED cases

**Files:**
- Create: `Tests/iOS/yuedu appTests/EPUBTestFixtures+MathML.swift`
- Modify: `Tests/iOS/yuedu appTests/MathMLBaselineTests.swift`
- Modify: `Tests/iOS/yuedu appTests/EPUBRenderingTests.swift`

- [ ] **Step 1: Add fixture factories for the approved formula set**

Change the existing `baseEntries` helper from `private` to internal and rename it `makeBaseEntries`, then update its current call sites. Extend `EPUBTestFixtures` with `mathMLTypography()` containing seven short paragraphs: inline identifier, super/subscript, fraction, square root/fence, multi-row matrix, over-wide display expression, and well-formed empty MathML with `alttext="quadratic expression"` that deterministically normalizes to no LaTeX. Add `mathMLWithoutUsefulAlt()` for the same empty MathML whose alt is `Alternative text not available`.

```swift
extension EPUBTestFixtures {
    static func mathMLTypography() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "MathML Typography",
            language: "en",
            body: """
            <p id="identifier">Before <math display="inline" alttext="x"><mi>x</mi></math> after.</p>
            <p id="scripts"><math display="inline" alttext="x squared sub n"><msubsup><mi>x</mi><mi>n</mi><mn>2</mn></msubsup></math></p>
            <p id="fraction"><math display="inline" alttext="a over b"><mfrac><mi>a</mi><mi>b</mi></mfrac></math></p>
            <p id="root"><math display="inline" alttext="root x in parentheses"><mfenced><msqrt><mi>x</mi></msqrt></mfenced></math></p>
            <p id="matrix"><math display="block" alttext="two by two matrix"><mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr></mtable></math></p>
            <p id="wide"><math display="block" alttext="long aligned equation"><mrow><mi>abcdefghijklmnopqrstuvwxyz</mi><mo>=</mo><mi>abcdefghijklmnopqrstuvwxyz</mi></mrow></math></p>
            <p id="empty">Before <math display="inline" alttext="quadratic expression"></math> after.</p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }
}
```

- [ ] **Step 2: Add failing fallback and paragraph-width tests**

Add tests that require an empty conversion result to preserve the useful alt, generic alt to become `[math]`, surrounding text to remain present, every math attachment to fit a 220-point decorated paragraph, and no attachment to have `ascent + descent != drawHeight`.

```swift
@Test @MainActor func emptyMathPreservesUsefulAltInsteadOfDisappearing() async {
    let attributed = await EPUBTestFixtures.renderIR(
        html: #"<p>Before <math alttext="quadratic expression"></math> after.</p>"#,
        config: EPUBTestFixtures.htmlConfig(renderWidth: 220)
    )
    #expect(attributed.string.contains("Before"))
    #expect(attributed.string.contains("[quadratic expression]"))
    #expect(attributed.string.contains("after"))
}

@Test @MainActor func formulaUsesDecoratedParagraphWidthBeforeRasterization() async throws {
    let result = await renderMathFixture(width: 220, horizontalInsets: 24)
    for run in EPUBTestFixtures.imageRunInfos(in: result) where run.info.source == "mathml:" {
        #expect(run.info.drawWidth <= 172.5)
        #expect(abs(run.info.ascent + run.info.descent - run.info.drawHeight) <= 1)
    }
}
```

- [ ] **Step 3: Ask the user to run focused RED tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/MathMLBaselineTests' \
  -only-testing:'yuedu appTests/EPUBRenderingTests' \
  -parallel-testing-enabled NO
```

Expected: at least the empty-conversion fallback test fails because failed conversion currently becomes a generic inline element; paragraph-width/raster assertions identify any second-stage scaling. If a proposed RED case passes at the baseline, mark it baseline-supported and retain it as regression coverage rather than weakening the assertion.

- [ ] **Step 4: Commit the characterization fixtures/tests**

```bash
git add 'Tests/iOS/yuedu appTests/EPUBTestFixtures.swift' \
  'Tests/iOS/yuedu appTests/EPUBTestFixtures+MathML.swift' \
  'Tests/iOS/yuedu appTests/MathMLBaselineTests.swift' \
  'Tests/iOS/yuedu appTests/EPUBRenderingTests.swift'
git commit -m "test: characterize MathML attachment failures"
```

### Task 2: Make MathML conversion failure explicit in the IR

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/MathMLRendering.swift`
- Test: `Tests/iOS/yuedu appTests/EPUBRenderingTests.swift`

- [ ] **Step 1: Change the IR payload**

Replace the nonoptional LaTeX string with a result payload:

```swift
public struct MathMLPayload: Sendable {
    public let latex: String?
    public let alt: String?
    public let displayMode: MathDisplayMode
}

case mathML(MathMLPayload, style: RenderStyle = .none)
```

Update every switch exhaustively. The converter always emits `.mathML`, using `attributes["alttext"] ?? attributes["alt"]` and the optional result of `MathMLLatexConverter.latex(from:)`. It must not fall back to `.inline(tag:"math")`.

- [ ] **Step 2: Centralize fallback selection**

Change `fallbackText` to accept optional LaTeX and keep the exact policy:

```swift
static func fallbackText(alt: String?, latex: String?) -> String {
    let trimmedAlt = alt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedAlt.isEmpty,
       trimmedAlt.range(of: "alternative text not available", options: .caseInsensitive) == nil,
       trimmedAlt.count <= 80 {
        return "[\(trimmedAlt)]"
    }
    return "[math]"
}
```

When `latex == nil`, render fallback immediately with secondary-label color and `semanticTagAttribute = "math"`. When iosMath rejects nonnil LaTeX, use the same path. Never append the internal LaTeX source to reader-visible text.

- [ ] **Step 3: Run static checks and ask for GREEN tests**

Run:

```bash
xcrun swiftc -parse Modules/Core/ReaderCore/CoreText/RenderableNode.swift
xcrun swiftc -parse Modules/Core/ReaderCore/CoreText/MathMLRendering.swift
xcrun swiftc -parse Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift
xcrun swiftc -parse Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift
git diff --check
```

Provide the Task 1 focused `xcodebuild` command. Expected: fallback tests pass; unrelated EPUB rendering tests remain green.

- [ ] **Step 4: Commit fallback behavior**

```bash
git add Modules/Core/ReaderCore/CoreText/RenderableNode.swift \
  Modules/Core/ReaderCore/CoreText/MathMLRendering.swift \
  Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift \
  Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift \
  'Tests/iOS/yuedu appTests/EPUBRenderingTests.swift'
git commit -m "fix: preserve MathML fallback content"
```

### Task 3: Resolve formula geometry once against actual available width

**Files:**
- Create: `Modules/Core/ReaderCore/CoreText/MathMLAttachmentMetrics.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/MathMLRendering.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`
- Modify: `Tests/iOS/yuedu appTests/MathMLBaselineTests.swift`

- [ ] **Step 1: Add unit tests for the metric policy**

Test natural inline, width-clamped inline, display formula, and zero/invalid inputs without UIKit drawing. The policy must preserve aspect ratio and baseline fraction.

```swift
@Test func overWideFormulaScalesWidthHeightAndBaselineTogether() throws {
    let metrics = try #require(MathMLAttachmentMetrics.resolve(
        naturalSize: CGSize(width: 600, height: 120),
        naturalAscent: 90,
        naturalDescent: 30,
        availableWidth: 240,
        horizontalPadding: 0
    ))
    #expect(metrics.drawWidth == 240)
    #expect(metrics.drawHeight == 48)
    #expect(metrics.ascent == 36)
    #expect(metrics.descent == 12)
}
```

- [ ] **Step 2: Implement `MathMLAttachmentMetrics`**

Define `drawWidth`, `drawHeight`, `totalWidth`, `ascent`, `descent`, and `logicalScale`. Reject nonfinite/nonpositive values. Compute one scale `min(1, availableWidth / naturalWidth)` and multiply all vertical metrics by it. Require `abs(ascent + descent - drawHeight) <= 0.5` after rounding correction.

- [ ] **Step 3: Rasterize at the final logical size**

Change `MathMLImageRenderer.render` to accept `targetWidth` calculated from `availableImageWidth(in: mathCtx)`, not global `config.renderWidth`. Render the iosMath display list directly with `UIGraphicsImageRendererFormat.scale = UIScreen.main.scale`; return natural/display metrics already scaled to final logical points. The generic `resolvedImageMetrics` must not rescale a math image afterward.

In `renderMathML`, convert `MathMLAttachmentMetrics` to the renderer's private `ImageMetrics` exactly once and pass it via `precomputedMetrics`.

- [ ] **Step 4: Ask the user to run GREEN tests**

Use the Task 1 command. Expected: identifier/fraction/matrix/over-wide metrics pass, `drawWidth` respects decorated paragraph width, and no formula clips or reserves inconsistent height.

- [ ] **Step 5: Commit metric policy**

```bash
git add Modules/Core/ReaderCore/CoreText/MathMLAttachmentMetrics.swift \
  Modules/Core/ReaderCore/CoreText/MathMLRendering.swift \
  Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift \
  'Tests/iOS/yuedu appTests/MathMLBaselineTests.swift'
git commit -m "fix: size MathML attachments from final metrics"
```

### Task 4: Verify paged/scroll parity and preserve cache correctness

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/MathMLRendering.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`
- Modify: `Tests/iOS/yuedu appTests/MathMLBaselineTests.swift`
- Modify: `Tests/iOS/yuedu appTests/CoreTextScrollTests.swift`

- [ ] **Step 1: Add parity and cache-key tests**

Build the synthetic fixture at 220 and 390 points. Assert page attachment metrics and `CoreTextChunkSlicer` attachment rects match the same logical size; assert raster pixel dimensions are at least logical dimensions multiplied by `image.scale`. Add a paginator fingerprint assertion proving changed math attachment width invalidates a cached layout.

- [ ] **Step 2: Include every layout-affecting MathML value in cache identity**

The paginator already hashes `ImageRunInfo.width`, ascent, descent, draw width, and draw height. Add a test that locks this behavior. Only modify production fingerprint code if the test demonstrates a missing value; do not add duplicate hash inputs.

- [ ] **Step 3: Ask the user to run focused parity tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/MathMLBaselineTests' \
  -only-testing:'yuedu appTests/CoreTextScrollTests' \
  -parallel-testing-enabled NO
```

Expected: all math attachments have consistent logical geometry in paged and scroll paths; raster dimensions meet device-scale clarity.

- [ ] **Step 4: Commit parity coverage**

```bash
git add Modules/Core/ReaderCore/CoreText/MathMLRendering.swift \
  Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift \
  'Tests/iOS/yuedu appTests/MathMLBaselineTests.swift' \
  'Tests/iOS/yuedu appTests/CoreTextScrollTests.swift'
git commit -m "test: protect MathML paged scroll parity"
```

### Task 5: Capture official-sample evidence and update the matrix

**Files:**
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/README.md`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/before.png`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/after.png`
- Modify: `docs/build-week/epub3/compatibility-matrix.md`

- [ ] **Step 1: Capture identical Linear Algebra checkpoints**

Use the baseline and current builds with the same sample checksum, iPhone 17 Pro Max simulator, iOS version, portrait orientation, theme, font size, margins, and chapter checkpoint. Capture inline baseline plus one matrix/over-wide display formula. Use the smallest crop that shows the difference.

- [ ] **Step 2: Record evidence metadata**

The evidence README names `dd62d80`, the final fixing commit, sample checksum/license, exact fixture/test, expected/observed result, and focused test command. If more than one distinct MathML bug was fixed, allocate sequential evidence IDs rather than hiding multiple commits under one row.

- [ ] **Step 3: Update and validate the matrix**

Mark only reproduced/fixed dimensions `build-week-fixed`; retain baseline-passing dimensions as `baseline-supported` in notes.

```bash
python3 scripts/epub3_samples.py matrix-check
git diff --check
git add docs/build-week/epub3/evidence/BW-EPUB3-001 docs/build-week/epub3/compatibility-matrix.md
git commit -m "docs: record MathML compatibility evidence"
```

## Completion Gate

This plan is complete when conversion and render failures retain fallback text, final formula metrics are calculated once from actual available width, raster pixels remain sharp at final logical size, paged and scroll geometry agree, focused user-run tests pass, and official-sample evidence links only post-`27c0650` fixes. It is not complete merely because the original identifier baseline test passes.
