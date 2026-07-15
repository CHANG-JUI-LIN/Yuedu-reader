# Language-Aware English EPUB Typography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Propagate EPUB language metadata into CoreText, honor CSS hyphenation policy without shifting source offsets, and justify eligible English lines without applying CJK spacing rules or creating excessive word gaps.

**Architecture:** Add a small language/hyphenation policy module and carry its values through Config → ResolvedStyle → RenderStyle → RenderContext → NSAttributedString. Native CoreText language attributes and paragraph hyphenation perform line breaking; a one-code-unit layout-only substitution suppresses authored soft hyphens for `hyphens:none` while preserving every UTF-16 offset. A pure `EnglishLineJustificationPolicy` decides whether the horizontal drawer may call `CTLineCreateJustifiedLine`.

**Tech Stack:** Swift 6, SwiftSoup HTML/CSS AST, CoreText, `NSParagraphStyle`, Swift Testing, existing paged and scroll reader paths.

---

## Prerequisite

Complete the corpus harness and record baseline Moby Dick and The Waste Land checkpoints. Do not tune thresholds from a single screenshot; keep the design's 82% coverage and two-breakable-space rules unless a focused test proves the rule internally inconsistent.

## File Responsibility Map

- `Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift`: normalized BCP-47-ish language tags, Latin-language support decision, `EPUBHyphenationPolicy`, native attribute keys, and pure English justification policy.
- `Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift`: document language input, element language inheritance, resolved hyphenation state, source element tags, and custom layout attributes.
- `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`: mirrors language and hyphenation in `RenderStyle`.
- `Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift`: copies language/hyphenation from resolved style to render style.
- `Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift`: supplies package `dc:language` as document fallback.
- `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`: writes native language, paragraph hyphenation factor, source element tag, and policy attributes into final ranges.
- `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`: includes language/hyphenation in layout fingerprint and applies 1:1 soft-hyphen suppression to a layout copy for `none` ranges.
- `Modules/Core/ReaderCore/CoreText/TextSelectionManager.swift`: reconstructs authored soft hyphens from the prepared layout copy when extracting selected text.
- `Modules/Core/ReaderCore/CoreText/CoreTextHorizontal/CoreTextHorizontalLineDrawer.swift`: invokes pure Latin justification policy while preserving current CJK behavior.
- `Tests/iOS/yuedu appTests/EPUBTestFixtures+EnglishTypography.swift`: minimal synthetic EPUB fixtures.
- `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`: resolver, CSS, offset, line-break, justification, cache, paged, and scroll assertions.

### Task 1: Add pure language, hyphenation, and justification policies

**Files:**
- Create: `Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift`
- Create: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`

- [ ] **Step 1: Write failing pure-policy tests**

Cover trimming/normalization (`en_US` → `en-US`), primary language detection, supported Latin language checks, invalid tags, CSS keyword parsing, and all English justification guards.

```swift
@Suite("English EPUB typography", .serialized)
struct EnglishEPUBTypographyTests {
    @Test func normalizesDeclaredLanguage() {
        #expect(EPUBLanguageTypography.normalizedLanguage(" en_US ") == "en-US")
        #expect(EPUBLanguageTypography.normalizedLanguage("!!!") == nil)
        #expect(EPUBLanguageTypography.primaryLanguage("en-GB") == "en")
    }

    @Test func latinJustificationRequiresAllQualityGuards() {
        let eligible = EnglishLineJustificationInput(
            text: "Several ordinary English words fill this line",
            coverage: 0.84,
            isParagraphLastLine: false,
            alignment: .justified,
            baseWritingDirection: .leftToRight,
            semanticTag: "p"
        )
        #expect(EnglishLineJustificationPolicy.shouldJustify(eligible))
        var lowCoverage = eligible
        lowCoverage.coverage = 0.81
        var finalLine = eligible
        finalLine.isParagraphLastLine = true
        var code = eligible
        code.sourceElementTag = "code"
        #expect(!EnglishLineJustificationPolicy.shouldJustify(lowCoverage))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(finalLine))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(code))
    }
}
```

- [ ] **Step 2: Ask the user to run RED**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -parallel-testing-enabled NO
```

Expected: compile failure because the policy types do not exist.

- [ ] **Step 3: Implement focused policy types**

```swift
enum EPUBHyphenationPolicy: String, Sendable {
    case unspecified
    case none
    case manual
    case auto
}

enum EPUBLanguageTypography {
    static let languageAttribute = NSAttributedString.Key(kCTLanguageAttributeName as String)
    static let hyphenationPolicyAttribute = NSAttributedString.Key("ReaderEPUBHyphenationPolicy")
    static let sourceElementTagAttribute = NSAttributedString.Key("ReaderHTMLSourceElementTag")
    static let originalSoftHyphenAttribute = NSAttributedString.Key("ReaderOriginalSoftHyphen")

    static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let subtags = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = subtags.first,
              (2...8).contains(first.count),
              first.allSatisfy({ $0.isLetter }),
              subtags.dropFirst().allSatisfy({
                  (1...8).contains($0.count) && $0.allSatisfy { $0.isLetter || $0.isNumber }
              })
        else { return nil }
        return subtags.enumerated().map { index, subtag in
            if index == 0 { return subtag.lowercased() }
            if subtag.count == 2, subtag.allSatisfy({ $0.isLetter }) { return subtag.uppercased() }
            return subtag.lowercased()
        }.joined(separator: "-")
    }

    static func primaryLanguage(_ raw: String?) -> String? {
        normalizedLanguage(raw)?.split(separator: "-").first.map(String.init)
    }
    static func supportsAutomaticHyphenation(_ raw: String?) -> Bool {
        ["en", "fr", "de", "es", "it", "pt", "nl"].contains(primaryLanguage(raw) ?? "")
    }
}
```

`EnglishLineJustificationInput` is a value type whose properties are mutable so guard variants can be derived in tests. `EnglishLineJustificationPolicy.shouldJustify` returns true only for `.justified`, LTR/natural direction, nonfinal lines, coverage ≥ 0.82, at least two spaces whose adjacent characters are nonwhitespace, Latin-dominant text, and source element tags other than `h1`–`h6`, `pre`, `code`, and `math`.

- [ ] **Step 4: Run static checks and request GREEN**

Run `xcrun swiftc -parse` on the new file and `git diff --check`; give the user the focused command. Expected: pure policy tests pass.

- [ ] **Step 5: Commit policies**

```bash
git add Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift \
  'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift'
git commit -m "feat: define EPUB language typography policies"
```

### Task 2: Propagate package and element language through the unified IR

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`
- Create: `Tests/iOS/yuedu appTests/EPUBTestFixtures+EnglishTypography.swift`
- Modify: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`

- [ ] **Step 1: Add failing language precedence tests**

Build a synthetic EPUB whose package language is `en-US`, body overrides to `en-GB`, one nested span uses `xml:lang="fr"`, and a sibling uses invalid `lang="!!!"`. Assert the final CoreText language attribute is `en-GB`, `fr`, and inherited `en-GB` respectively. Add a package-only document test that resolves `en-US`.

```swift
@Test @MainActor func elementLanguageOverridesPackageWithoutChangingTextRanges() async throws {
    let attributed = try await renderEnglishFixture()
    #expect(attributed.attribute(EPUBLanguageTypography.languageAttribute, near: "colour") as? String == "en-GB")
    #expect(attributed.attribute(EPUBLanguageTypography.languageAttribute, near: "français") as? String == "fr")
    #expect(attributed.attribute(EPUBLanguageTypography.languageAttribute, near: "fallback") as? String == "en-GB")
}
```

- [ ] **Step 2: Add language fields consistently**

- `HTMLAttributedStringBuilder.Config.documentLanguage: String? = nil`
- `ResolvedStyle.language: String?`
- `RenderStyle.language: String?`
- `NodeAttributedStringRenderer.Config.documentLanguage: String?`
- `RenderContext.language: String?`

Root style uses normalized `config.documentLanguage`. Child style inherits parent language. In `resolvedStyle`, read `xml:lang` first, then `lang`; a valid value overrides, an invalid value leaves inherited language unchanged. Include `lang` and `xml:lang` in `makeAttributeMap` for diagnostic parity.

`EPUBAttributedStringBuilder.makeConfig` passes `session.language`; renderer config receives the same normalized fallback. `RenderStyle.from` copies the resolved language. `RenderContext.baseAttributes` adds the native CoreText language key only when nonnil. Add `sourceElementTagAttribute` for every rendered element, filling only ranges that do not already carry a child tag; this preserves inner `code`/`math` identity while giving direct heading and paragraph text `h1`–`h6`/`p` identity. Keep the existing narrower `semanticTagAttribute` behavior unchanged.

- [ ] **Step 3: Run parse checks and request focused GREEN**

Run `xcrun swiftc -parse` on all five production files and `git diff --check`; ask the user to run `EnglishEPUBTypographyTests`. Expected: precedence tests pass and attributed string length/string remain unchanged.

- [ ] **Step 4: Commit language propagation**

```bash
git add Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift \
  Modules/Core/ReaderCore/CoreText/RenderableNode.swift \
  Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift \
  Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift \
  Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift \
  'Tests/iOS/yuedu appTests/EPUBTestFixtures+EnglishTypography.swift' \
  'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift'
git commit -m "feat: propagate EPUB language into CoreText"
```

### Task 3: Parse CSS hyphenation and apply native paragraph policy

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/RenderableNode.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`
- Modify: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`

- [ ] **Step 1: Write failing CSS cascade tests**

Test `hyphens`, `-webkit-hyphens`, and `-epub-hyphens`. Within one declaration band, standard `hyphens` wins over `-epub-hyphens`, which wins over `-webkit-hyphens`; across rules and normal/important bands, the existing call order remains authoritative. Assert `none=0`, `manual=0`, `auto=1`, and unspecified justified English body resolves to 1. Unspecified left-aligned text and unsupported language resolve to 0.

- [ ] **Step 2: Add the grouped CSS resolver and mirrored style field**

At the start of `HTMLAttributedStringBuilder.apply(declarations:to:context:)`, resolve the alias group once with `declarations["hyphens"] ?? declarations["-epub-hyphens"] ?? declarations["-webkit-hyphens"]`. Map `none|manual|auto` directly, `initial` to `.unspecified`, and `inherit|unset` to `context.parentStyle.hyphenationPolicy`; ignore invalid values. This avoids dictionary iteration deciding alias precedence. Because `apply` is already invoked in cascade order for each normal/important band, later higher-priority calls still override earlier state. Root defaults to `.unspecified`; children inherit. Add the same field to `RenderStyle` and `RenderContext`.

In `applyBlockStyle`, resolve the native factor:

```swift
let allowsAutomatic = EPUBLanguageTypography.supportsAutomaticHyphenation(newCtx.language)
switch style.hyphenationPolicy {
case .auto:
    para.hyphenationFactor = allowsAutomatic ? 1 : 0
case .unspecified:
    para.hyphenationFactor = allowsAutomatic && style.textAlign == .justify ? 1 : 0
case .manual, .none:
    para.hyphenationFactor = 0
}
newCtx.hyphenationPolicy = style.hyphenationPolicy
```

`baseAttributes` always writes `hyphenationPolicyAttribute` so the paginator can distinguish `.none` from `.manual` even though both have native factor 0.

- [ ] **Step 3: Request RED/GREEN cycle**

Run parse checks; ask the user to run the focused test before and after implementation. Expected: CSS and paragraph-factor assertions pass without altering CJK paragraph defaults.

- [ ] **Step 4: Commit CSS/native hyphenation**

```bash
git add Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift \
  Modules/Core/ReaderCore/CoreText/RenderableNode.swift \
  Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift \
  Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift \
  'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift'
git commit -m "feat: honor EPUB hyphenation policy"
```

### Task 4: Suppress soft-hyphen breaks for `hyphens:none` without offset drift

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/TextSelectionManager.swift`
- Modify: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`

- [ ] **Step 1: Write failing source-offset and line-break tests**

Use text `extra\u{00AD}ordinary marker` at narrow width. For `.manual`, assert at least one line boundary can occur at the soft hyphen. For `.none`, assert no line ends at that location. In both modes, assert prepared string UTF-16 length equals source length and the `marker` offset is unchanged.

- [ ] **Step 2: Add horizontal layout preparation**

Refactor `preparedAttributedString` so horizontal mode can make a mutable layout copy only when a `.none` range contains U+00AD. Replace each matching soft hyphen with U+2060 WORD JOINER, a one-UTF-16-unit nonbreaking invisible character, and attach `originalSoftHyphenAttribute = true` at that unit. Do not mutate the production attributed string returned by the builder. Vertical preparation runs the same suppression before vertical normalization.

Add `EPUBLanguageTypography.sourceText(in:range:)`: take the attributed substring, replace U+2060 with U+00AD only at units carrying `originalSoftHyphenAttribute`, and return its string. Change `TextSelectionManager.selectedText(in:)` to call this helper. Both paged and scroll controllers already copy `selectedTextForCopy`, so this single extraction point restores authored text without changing selection ranges or controller code.

- [ ] **Step 3: Add cache fingerprint inputs**

Hash `paragraphStyle.hyphenationFactor`, normalized language attribute, and `hyphenationPolicyAttribute`. Add a test proving a policy/language change causes a different layout fingerprint/cache miss while the source string remains identical.

- [ ] **Step 4: Ask the user to run focused GREEN tests**

Use the focused English suite command. Expected: `none` suppresses the break, `manual` honors it, and every downstream char offset remains stable.

- [ ] **Step 5: Commit offset-safe suppression**

```bash
git add Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift \
  Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift \
  Modules/Core/ReaderCore/CoreText/TextSelectionManager.swift \
  'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift'
git commit -m "fix: preserve offsets while suppressing soft hyphens"
```

### Task 5: Add guarded English line justification

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextHorizontal/CoreTextHorizontalLineDrawer.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift`
- Modify: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`

- [ ] **Step 1: Add failing CTLine geometry tests**

Build justified English paragraphs at 280, 320, and 390 points. Assert eligible nonfinal lines reach the available right edge within 1 point, last lines keep natural width, short lines below 82% remain natural, headings/code/pre remain natural, and existing CJK eligible lines still justify.

- [ ] **Step 2: Route Latin lines through the pure policy**

Keep the current trailing-kern removal. Read language, source element tag, paragraph alignment/direction, text, coverage, and final-line state from the line range. Selection behavior is:

```swift
if shouldUseCJKJustify {
    return CTLineCreateJustifiedLine(naturalLine, 1.0, Double(availableWidth)) ?? naturalLine
}
if EnglishLineJustificationPolicy.shouldJustify(input) {
    return CTLineCreateJustifiedLine(naturalLine, 1.0, Double(availableWidth)) ?? naturalLine
}
return naturalLine
```

Do not classify RTL lines as English; do not lower the CJK coverage threshold or change CJK dominance rules.

- [ ] **Step 3: Ask the user to run English and CJK suites**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -only-testing:'yuedu appTests/CoreTextPipelineTests' \
  -parallel-testing-enabled NO
```

Expected: English edge/guard tests pass and CJK typography remains green.

- [ ] **Step 4: Commit English justification**

```bash
git add Modules/Core/ReaderCore/CoreText/CoreTextHorizontal/CoreTextHorizontalLineDrawer.swift \
  Modules/Core/ReaderCore/CoreText/EPUBLanguageTypography.swift \
  'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift'
git commit -m "fix: justify eligible English EPUB lines"
```

### Task 6: Verify paged/scroll parity and interaction offsets

**Files:**
- Modify: `Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift`
- Modify: `Tests/iOS/yuedu appTests/CoreTextScrollTests.swift`
- Modify: `Tests/iOS/yuedu appTests/EPUBRenderingTests.swift`

- [ ] **Step 1: Add full-pipeline parity tests**

Open `EPUBTestFixtures.englishTypography()`, build through `PublicationSession` and `EPUBAttributedStringBuilder`, paginate and slice the same attributed string, and assert language/hyphenation attributes survive chunk ranges. Verify link range, anchor offset, selection string, and text after a soft hyphen retain source UTF-16 offsets.

- [ ] **Step 2: Add Moby Dick-shaped chapter boundary test**

Use two synthetic English spine chapters with package `en-US`; assert each chapter builds nonempty, starts with its own language attribute, and produces continuous independent page/chunk ranges. Do not copy official prose.

- [ ] **Step 3: Ask the user to run parity suites**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -only-testing:'yuedu appTests/CoreTextScrollTests' \
  -only-testing:'yuedu appTests/EPUBRenderingTests' \
  -parallel-testing-enabled NO
```

Expected: paged/scroll attributes and ranges agree; links, selection, TTS-facing offsets, and anchors do not drift.

- [ ] **Step 4: Commit parity protection**

```bash
git add 'Tests/iOS/yuedu appTests/EnglishEPUBTypographyTests.swift' \
  'Tests/iOS/yuedu appTests/CoreTextScrollTests.swift' \
  'Tests/iOS/yuedu appTests/EPUBRenderingTests.swift'
git commit -m "test: protect English EPUB typography parity"
```

### Task 7: Capture official-sample evidence and update the matrix

**Files:**
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/README.md`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/before.png`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/after.png`
- Modify: `docs/build-week/epub3/compatibility-matrix.md`

- [ ] **Step 1: Capture Moby Dick and Waste Land checkpoints**

Use identical baseline/current settings. Capture one justified paragraph with a long word and one embedded-font paragraph. Record sample checksum, exact chapter/href, device/iOS, width, theme, font size, and margins.

- [ ] **Step 2: Record claims precisely**

Evidence notes separate baseline-supported embedded font/loading behavior from post-`27c0650` language/hyphenation/justification changes. If Moby Dick and Waste Land expose distinct bugs with different commits, assign separate evidence IDs.

- [ ] **Step 3: Validate and commit evidence**

```bash
python3 scripts/epub3_samples.py matrix-check
git diff --check
git add docs/build-week/epub3/evidence/BW-EPUB3-002 docs/build-week/epub3/compatibility-matrix.md
git commit -m "docs: record English EPUB typography evidence"
```

## Completion Gate

This plan is complete when language precedence reaches native CoreText attributes, CSS hyphenation policies behave as specified, `hyphens:none` preserves UTF-16 offsets, eligible English lines justify with quality guards, CJK/RTL behavior remains unchanged, paged/scroll/interaction tests pass under user-run Xcode commands, and official-sample evidence links only actual baseline failures and post-`27c0650` commits.
