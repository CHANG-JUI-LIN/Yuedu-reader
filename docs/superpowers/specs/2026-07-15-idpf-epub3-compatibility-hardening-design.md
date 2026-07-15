# IDPF EPUB 3 Sample-Driven Compatibility Hardening Design

## Status

This document records the design approved during brainstorming. It is awaiting review of the written specification before implementation planning begins.

## Product Context

Yuedu Reader is a native iOS reader for user-owned books and user-chosen sources. It imports TXT, EPUB, CBZ, and ZIP files; supports Legado book sources, browser conversion, RSS, OPDS, WebDAV, and local-network import; and offers advanced typography and paid layout customization.

The product belongs in `Apps for Your Life`. Its positioning is:

- `Premium native reading, without ecosystem lock-in.`
- `Your books. Your sources. Your reading experience.`

The Build Week story is not that Yuedu has started supporting EPUB 3. Yuedu already has a native CoreText reading engine and substantial EPUB support. The new work is a measurable compatibility-hardening campaign driven by the official [IDPF EPUB 3 Samples](https://idpf.github.io/epub3-samples/30/samples.html).

## Provenance and Attribution Boundaries

Two Git boundaries have different purposes:

- Build Week eligibility baseline: tag `build-week-baseline`, commit `dd62d80`, dated 2026-07-13 21:56 +08:00.
- This EPUB 3 initiative's working start: branch `codex/openai-build-week`, commit `27c0650`, dated 2026-07-15 05:43 +08:00.

Commits between these points contain other Build Week work, primarily reader-overlay changes. They remain in branch history but are outside this EPUB 3 initiative. They must not appear in the EPUB compatibility matrix or be presented as sample-driven compatibility fixes.

CFI, the existing MathML pipeline, Ruby, fixed layout, Media Overlay, audio/video, RTL/Bidi, PLS/SSML, and other capabilities that existed at `build-week-baseline` are baseline capabilities. A baseline capability may be regression-tested during this initiative, but it counts as new work only when a post-`27c0650` commit fixes a failure demonstrated against the baseline tag.

No changes from `main` are to be merged or cherry-picked into this branch during this initiative unless they are separately reviewed and explicitly identified as required dependencies. All EPUB 3 work and evidence commits are made directly on `codex/openai-build-week`.

## Decision Record

Three approaches were considered:

1. **Official-sample-driven compatibility engineering — selected.** Build a repeatable corpus workflow, establish a baseline matrix, fix MathML and English typography gaps, then select at least three additional high-impact failures found by the corpus.
2. **MathML-only showcase.** This offers a strong visual before/after but makes the product look narrower than it is and does not address the recurring small EPUB issues reported by the user.
3. **Claim complete EPUB 3 support.** Rejected. The official catalog includes specialized features such as bindings, Canvas, Region-Based Navigation, and Multiple Renditions that cannot responsibly be promised in one week.

The selected approach improves the production renderer rather than creating a demo-only renderer or a new WebView reading path.

## Goals

By the end of this initiative:

1. Every EPUB download listed in the official sample catalog is represented in a committed manifest and attempted by automated structural scanning.
2. Eight representative books receive focused manual review with documented checkpoints.
3. The production CoreText path gains verified improvements for:
   - MathML inline baseline, sizing, raster clarity, over-wide formulas, and complex-formula fallback;
   - language-aware English hyphenation and justified paragraph quality;
   - at least three additional high-impact gaps selected from observed official-sample failures.
4. Every claimed fix has:
   - reproducible before/after evidence;
   - a dedicated commit;
   - a minimal synthetic fixture in `EPUBTestFixtures`;
   - a focused automated regression test;
   - a compatibility-matrix entry linking the evidence, test, and commit.
5. Unsupported features do not crash, erase ordinary fallback children, or silently produce an empty chapter. They retain useful alt text, static fallback content, or an explicit readable placeholder.

## Non-Goals

- Complete support for every EPUB 3 feature.
- A user-facing compatibility dashboard.
- A second renderer, WebView fallback reader, or CoreText engine rewrite.
- Full interactive support for bindings, quizzes, Canvas, Region-Based Navigation, or Multiple Renditions.
- Treating baseline capabilities as Build Week additions.
- Committing the downloaded official EPUB corpus.
- Running every chapter of every official book through a visual snapshot test.
- Replacing iosMath or the MathML-to-LaTeX bridge during this initiative.
- A whole-app accessibility or typography redesign unrelated to failures found by the selected corpus.

## Repository Layout

Implementation will use these boundaries:

```text
docs/build-week/epub3/
  README.md
  sample-manifest.json
  compatibility-matrix.md
  evidence/BW-EPUB3-001/

scripts/
  epub3_samples.py

.build-week/epub3-samples/       # ignored; official EPUB binaries and generated local reports

Tests/BuildWeek/IDPFEPUB3CorpusTests/
  IDPFEPUB3SampleSmokeTests.swift

Tests/iOS/yuedu appTests/
  EPUBTestFixtures+EnglishHyphenation.swift  # one small extension per defect family
  EnglishEPUBTypographyTests.swift            # one focused suite per defect family
```

`.build-week/` is added to `.gitignore`. Official EPUB binaries, extracted official books, derived raster output, and local raw scan logs stay under that ignored directory. Only the manifest, matrix, small synthetic fixtures, tests, selected evidence, and documentation are committed.

## Corpus Manifest

`sample-manifest.json` is the stable source of truth for the external corpus. Runtime HTML scraping is not used because catalog changes would make old results unreproducible.

Each sample entry contains:

- stable `id` and official title;
- official GitHub release asset URL;
- catalog URL and license/attribution note;
- expected filename and SHA-256 checksum;
- declared EPUB feature tags;
- designated smoke targets by spine href or chapter index;
- visible-text, image, or fallback probes used to detect swallowed content;
- whether the sample belongs to the manual representative set;
- manual checkpoints and capability-specific exclusions.

The manifest covers every downloadable row and variant in the official catalog, not only the eight manually reviewed books. A validation command rejects duplicate IDs, duplicate output paths, missing checksums, non-HTTPS download URLs, missing license notes, and matrix rows that do not map back to a manifest entry.

During initial manifest construction, each official asset is downloaded to a temporary ignored location and its checksum is recorded before the first manifest commit. After that bootstrap commit, `fetch` requires and verifies the committed checksum. A later checksum change is treated as an upstream corpus revision that requires an explicit manifest commit; it is never silently accepted.

## Corpus Tooling

`scripts/epub3_samples.py` uses only the Python 3 standard library and exposes three commands:

```text
fetch         Download and checksum all or selected official samples.
scan          Perform package-level checks and write local JSON results.
matrix-check  Validate manifest/matrix/evidence referential integrity.
```

### Fetch behavior

- Downloads into a temporary file, verifies the ZIP signature and SHA-256, then atomically moves the file into `.build-week/epub3-samples/books/`.
- Reuses a valid cached file and supports an explicit force-redownload option.
- Prevents archive path traversal during inspection or extraction.
- Attempts all requested samples and reports all failures together; one network error does not hide later results.
- Returns nonzero when any requested sample is missing, corrupt, or checksum-mismatched.

### Static scan behavior

The scanner checks, without launching the app:

- `mimetype`, `META-INF/container.xml`, and package-document discovery;
- OPF parsing, manifest and spine consistency, and unique manifest IDs;
- existence of spine items, navigation documents, CSS, images, fonts, MathML-bearing XHTML, SMIL, audio/video, SVG, and declared fallbacks;
- unsafe paths and missing referenced local resources;
- feature signals used to classify the corpus, such as fixed layout, RTL, vertical writing, MathML, Ruby, scripted content, bindings, and multiple renditions.

It writes machine-readable results under `.build-week/epub3-samples/results/`. These results are input evidence for the committed matrix, not production parser verdicts: a structurally valid package can still fail Yuedu rendering.

## Production-Pipeline Smoke Checks

`IDPFEPUB3SampleSmokeTests` is opt-in because the external binaries are not committed. It runs only when `YUEDU_RUN_EPUB3_CORPUS=1` is set and reads the corpus directory from `YUEDU_EPUB3_CORPUS_DIR`. With the opt-in flag enabled, a missing corpus, checksum mismatch, or incomplete manifest is a test failure rather than a skip.

The suite lives in the dedicated hosted unit-test target `IDPFEPUB3CorpusTests`, exposed by the shared `Yuedu-Reader EPUB3 Corpus` scheme. This isolates corpus triage from unrelated compile debt in the monolithic `yuedu appTests` target while preserving `@testable import yuedu_app`; focused synthetic regression fixtures discovered by the corpus still belong to the normal test target.

Each parameterized sample test uses production components:

```text
Yuedu-Reader EPUB3 Corpus scheme
→ IDPFEPUB3CorpusTests hosted target
→ official EPUB
→ PublicationSession.open
→ manifest/spine/navigation/resource resolution
→ EPUBAttributedStringBuilder
→ styled AST
→ RenderableNode
→ NodeAttributedStringRenderer
→ CoreText pagination or scroll slicing for designated chapters
```

The checks assert, as applicable:

- the publication opens and has a nonempty reading order;
- designated chapter resources resolve;
- designated chapters build without throwing;
- the rendered result has visible text, an image page, or an expected explicit fallback;
- text probes from fallback children remain present;
- paged layout produces at least one valid page range;
- paged ranges cover the attributed string continuously except for ranges fully marked with the production `pageBreakAttribute`; no other gap or any overlap is allowed;
- scroll layout produces at least one valid chunk when the format supports scroll mode;
- no range exceeds its attributed-string bounds;
- fixed-layout and image-in-spine samples use their capability-specific path instead of being forced through reflow assertions.

The full-corpus suite is a triage tool, not the permanent regression suite. Once a real defect is found, the official book is reduced to the smallest legal synthetic EPUB in an `EPUBTestFixtures` extension. The focused fixture and test run without network access or external corpus files and become the CI-safe regression protection.

## Compatibility Matrix

`compatibility-matrix.md` contains one row per manifest entry and these evidence columns:

- primary feature and expected behavior;
- baseline result at `build-week-baseline`;
- current static scan result;
- `PublicationSession` open result;
- designated chapter render result;
- paged/scroll result where applicable;
- manual result for representative samples;
- final outcome;
- linked issue ID, fixture, test, evidence, and fixing commit.

Allowed final outcomes are:

- `baseline-supported`: verified at the baseline tag; not a new Build Week claim;
- `build-week-fixed`: failed at baseline and passes after a linked post-`27c0650` fix;
- `readable-fallback`: the specialized feature is not interactive, but ordinary content or a static/alt fallback remains readable;
- `unsupported-safe`: unsupported and without a rich fallback, but opening and navigation remain stable and the limitation is explicit;
- `failing`: crash, empty content, missing required resource, broken navigation, or materially unreadable output;
- `not-run`: evidence has not yet been collected.

`not-run` is used instead of guessing. A capability is not marked `baseline-supported` merely because related code or an older unit test exists; it requires a result against `build-week-baseline` or pre-existing evidence that can be tied to that commit.

### Baseline capture protocol

The corpus harness is implemented and committed before renderer fixes. To run it against `build-week-baseline`, create a temporary detached worktree from `dd62d80` and apply only the harness/test commit there; do not apply production renderer changes. The harness is deliberately limited to APIs already present at the baseline. The matrix records all three identities: baseline production commit `dd62d80`, harness commit, and official sample checksum.

Codex may prepare the detached worktree and exact commands, but the user runs the long Xcode test/build. Baseline screenshots and current-branch screenshots use the same simulator/device configuration and official EPUB checksum. The temporary worktree and build artifacts remain ignored and never alter `main` or `codex/openai-build-week` history.

## Representative Manual Set

The initial manual set contains exactly eight official samples:

| Sample | Primary checkpoints | Attribution rule |
| --- | --- | --- |
| Linear Algebra | Inline/display MathML, fractions, matrices, over-wide and complex formulas | Existing MathML support is baseline; only demonstrated metric/rendering fixes are new. |
| Moby Dick | English body rhythm, justified paragraphs, long words, embedded OpenType fonts, chapter boundaries | Typography fixes must also pass a synthetic English fixture. |
| The Waste Land with OTF fonts | Single-spine English layout, linked notes, semantic sections, embedded font fallback | Existing links and font loading are not new unless a baseline failure is fixed. |
| Children's Literature | Complex `nav.xhtml`, span headings, in-spine TOC, hidden page list | Hidden content must not create blank pages or leak into body text. |
| Accessible EPUB 3 | Semantic reading order, alt/static fallbacks, content retention | This is a content-preservation check, not a claim of complete assistive-technology conformance. |
| Israel Sailing | RTL/Bidi, Hebrew text, page progression, inline images | Existing RTL/Bidi support remains baseline unless the sample exposes a new defect. |
| Kusamakura | Vertical-writing metadata, Ruby, emphasis dots, non-ASCII resources, Media Overlay | This is primarily a regression/fallback probe; full vertical EPUB support is not promised. |
| Page Blanche | Fixed-layout viewport, spread/orientation metadata, bitmap page rendering | Existing fixed-layout support remains baseline unless a sample-specific failure is fixed. |

A sample may be substituted only when it cannot be legally downloaded or opened from the official release. The replacement must cover the same feature family and the reason must be recorded in the matrix.

Manual review is checkpoint-based rather than cover-to-cover reading. Each run records device/simulator model, iOS version, orientation, theme, font settings, page margins, reading mode, sample checksum, and exact chapter/page checkpoint.

## MathML Workstream

The existing architecture remains:

```text
MathML
→ MathMLToLaTeX JavaScript bridge and targeted table conversion
→ normalized LaTeX
→ iosMath 2.3.1
→ high-resolution raster
→ ImageRunInfo/CoreText attachment
```

The work is limited to improving this path, not replacing it.

### Metric and sizing policy

- iosMath display-list ascent and descent remain the source of truth for the math baseline.
- Attachment ascent, descent, draw height, and any width scaling are calculated together by one metric policy; callers do not apply a second independent scale.
- Inline formulas align their math baseline with the surrounding text baseline. Tall fractions, roots, superscripts, subscripts, and matrices reserve their full draw height without clipping adjacent lines.
- Display formulas use the actual reader content width after insets. Over-wide formulas preserve aspect ratio, are never cropped, and are rasterized at the final logical size using device-scale pixels so fitting does not create a low-resolution bitmap.
- A formula that cannot be converted or rendered emits meaningful `alttext`/`alt` when present. Generic or unavailable alt text becomes `[math]`; it never becomes an empty attachment.
- No formula splitting algorithm or new formula viewer is introduced this week. Existing image-preview behavior may be reused only if it already applies without new user-facing scope.

### MathML regression set

Minimal fixtures cover at least:

- a bare inline identifier between text runs;
- inline superscript/subscript and fraction;
- square root and fenced expression;
- a multi-row matrix/aligned table;
- a deliberately over-wide display formula;
- malformed or unsupported MathML with useful alt text;
- malformed or unsupported MathML without useful alt text.

Tests assert baseline tolerance, reserved-versus-drawn geometry, maximum width, raster scale, absence of clipping, and nonempty fallback text. Passing pre-existing cases are recorded as baseline verification, not new fixes.

## Language-Aware English Typography Workstream

### Language propagation

Language is resolved in this order:

1. the element's `xml:lang`;
2. the element's `lang`;
3. the nearest ancestor language;
4. the document/package `dc:language` supplied by `PublicationSession`;
5. no language when none is declared.

The resolved language flows through `HTMLAttributedStringBuilder.Config`, `ResolvedStyle`, `RenderStyle`, `RenderContext`, and the final attributed ranges. The final output uses the native language attribute consumed by CoreText. This propagation must be mirrored wherever `ResolvedStyle` and `RenderStyle` are converted so both paged and scroll paths receive identical attributes.

### Hyphenation policy

- CSS `hyphens: none` disables automatic and discretionary hyphenation for the range.
- CSS `hyphens: manual` honors authored soft hyphens but does not add automatic opportunities.
- CSS `hyphens: auto` enables native language-aware hyphenation for supported languages.
- When `hyphens` is unspecified, Yuedu enables automatic hyphenation only for justified body paragraphs in supported Latin languages; other paragraphs use manual behavior.
- Source text and UTF-16 offsets are not mutated to insert guessed hyphens. Stable `(spineIndex, charOffset)` positions, links, selection, TTS ranges, and annotations must remain valid.
- Unsupported or invalid language tags fall back to manual behavior rather than guessed English rules.

### Justification policy

English/Latin lines are no longer sent through the CJK-only branch. A Latin-dominant line is fully justified only when all of the following are true:

- the resolved paragraph alignment is justified;
- it is not the paragraph's final line;
- it contains at least two breakable word spaces;
- its natural width covers at least 82% of the available paragraph width;
- it is not a heading, preformatted/code block, or explicit fallback placeholder.

If these guards fail, the natural line is drawn. CJK-dominant behavior remains unchanged. RTL paragraphs remain on their existing direction-aware path and are not treated as English merely because they contain Latin digits or names.

### English regression set

Synthetic fixtures cover:

- `en-US` and `en-GB` language propagation;
- nested `lang`/`xml:lang` overrides;
- `hyphens: none`, `manual`, `auto`, and unspecified justified text;
- long English words at narrow, standard, and wide reader widths;
- justified non-final lines and natural final lines;
- headings, code/preformatted text, links, selection ranges, and stable offsets;
- parity between paged rendering and scroll chunks.

Tests favor structural metrics and line ranges over pixel snapshots. Manual Moby Dick and Waste Land checks provide the visual quality evidence.

## Selecting At Least Three Additional Gaps

Additional fixes are selected only after full-corpus static results and the first representative manual pass. Candidates are ranked in this order:

1. crash, hang, unsafe archive handling, or completely empty chapter;
2. swallowed fallback text, broken reading order, missing spine resource, or unusable navigation;
3. common reflow, image, SVG, font, or semantic behavior that materially harms reading;
4. specialized-feature fallback quality;
5. interactive or niche behavior with little effect on ordinary reading.

Each selected gap must:

- represent a distinct failure family rather than three variants of one bug;
- reproduce at `build-week-baseline`;
- be reduced to a legal synthetic fixture;
- be fixable in the shared production path without a sample-name special case;
- have a focused automated assertion and before/after evidence;
- preserve readable fallback when full feature support remains out of scope.

Likely discovery areas include navigation/page-list handling, `epub:switch` or foreign-content fallback, CSS media-query behavior, SVG/image-in-spine sizing, and accessible fallback retention. These are candidates, not promises; the observed matrix determines the final three or more.

## Failure and Fallback Contracts

Across all workstreams:

- A malformed sample produces a sample-scoped diagnostic and does not prevent other catalog entries from being scanned.
- Missing resources identify the referring manifest/spine item and resource href.
- A chapter with neither visible text, a valid image page, nor an explicit fallback is a failure.
- Unsupported interactive objects preserve ordinary child content. If no child fallback exists, they render a concise static placeholder rather than disappearing.
- MathML preserves alt text or `[math]` on conversion/render failure.
- Media, Canvas, bindings, Multiple Renditions, and Region-Based Navigation are never labeled supported merely because the book opens.
- Changes that affect attributed strings are verified in both paged and scroll paths when both paths support that publication type.
- No implementation branches on an official sample title, filename, or checksum.

## Evidence and Commit Protocol

Each issue receives a stable ID such as `BW-EPUB3-001` and an evidence directory containing:

- `README.md` with the sample/checkpoint, baseline commit, after commit, environment, expected behavior, observed behavior, fixture, and test command;
- `before.png` and `after.png` captured with identical device, settings, content, and crop;
- attribution when an official-sample excerpt is visible.

Prefer synthetic-fixture screenshots for committed evidence. If an official sample is necessary, include only the smallest useful excerpt and its license/attribution note. Third-party reader screenshots are not part of the repository evidence or submission video.

Fixes are committed separately after their fixture and focused test exist. The matrix links the fixing commit. Harness and documentation commits are separate from renderer fixes so the Build Week diff remains auditable.

## Verification

Fast checks that Codex may run directly during implementation:

```bash
python3 scripts/epub3_samples.py matrix-check
python3 scripts/epub3_samples.py scan
ruby scripts/check_localizations.rb
git diff --check
```

Long Xcode builds/tests are provided to the user rather than run directly. The intended focused commands are:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO

xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/MathMLBaselineTests' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -parallel-testing-enabled NO
```

The full-corpus command sets `TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1` and `TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR` to the ignored books directory; `xcodebuild` strips the `TEST_RUNNER_` prefix when forwarding them to the hosted test process. The exact shell invocation is documented in `docs/build-week/epub3/README.md`.

## Acceptance Criteria

The initiative is complete only when all of the following are true:

- The manifest covers every official catalog download and passes referential validation.
- Automated static scanning has attempted every manifest entry; failures remain visible rather than being omitted.
- The eight representative samples have completed manual checkpoints or a documented same-family substitution.
- MathML and English typography have before/after evidence for actual baseline failures, plus focused synthetic fixtures and tests.
- At least three additional distinct high-impact official-sample failures are fixed with the same evidence package.
- Every matrix row has an honest final outcome; no row remains ambiguously blank.
- Unsupported features satisfy the no-crash, no-swallowed-body, readable-fallback contract.
- Every claimed fix maps to a post-`27c0650` commit and does not claim unrelated overlay work or baseline EPUB capabilities.
- Official binaries remain ignored and absent from Git history.
- Fast validation passes, and the user reports passing focused Xcode commands or any failures are recorded without a false completion claim.

## Submission Narrative

The three-minute submission distinguishes product history from Build Week work:

- 0:00–0:25: Yuedu exists to combine premium native reading with an open content ecosystem.
- 0:25–0:50: CSS multi-column, snapshot, Readium, and WebView experiments led to a custom CoreText engine; the engine already supported substantial EPUB behavior before Build Week.
- 0:50–2:10: Show the strongest MathML, English typography, and additional official-sample-driven before/after results.
- 2:10–2:35: Show the compatibility matrix, minimized fixtures, and automated regression checks.
- 2:35–3:00: Explain how Codex and GPT-5.6 helped analyze the corpus, isolate failures, implement fixes, and preserve evidence.

The submission must say “official-sample-driven EPUB 3 compatibility hardening,” not “complete EPUB 3 support.”
